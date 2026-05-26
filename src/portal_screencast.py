#!/usr/bin/env python3
"""xdg-desktop-portal ScreenCast + GStreamer pipewiresrc encoder.

Usage: portal_screencast.py <output.mkv> <framerate>

Lifecycle:
  - Performs the portal dance (CreateSession, SelectSources, Start)
  - Opens a PipeWire remote, gets fd + stream node id
  - Launches a GStreamer pipeline encoding to H264 in Matroska
  - Runs until SIGINT/SIGTERM, then sends EOS for clean shutdown

On first run, GNOME shows a permission dialog. Subsequent runs reuse the grant.
"""
import os, sys, signal, secrets, urllib.parse

import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib

import dbus
from dbus.mainloop.glib import DBusGMainLoop


def main():
    if len(sys.argv) not in (3, 4):
        print(f"usage: {sys.argv[0]} <output> <framerate> [bitrate-kbps]", file=sys.stderr)
        sys.exit(2)
    out_path = sys.argv[1]
    framerate = int(sys.argv[2])
    bitrate_kbps = int(sys.argv[3]) if len(sys.argv) == 4 else 20000

    DBusGMainLoop(set_as_default=True)
    Gst.init(None)

    bus = dbus.SessionBus()
    portal = bus.get_object("org.freedesktop.portal.Desktop",
                            "/org/freedesktop/portal/desktop")
    screencast = dbus.Interface(portal, "org.freedesktop.portal.ScreenCast")

    sender = bus.get_unique_name().replace(".", "_")[1:]
    token = "onecap_" + secrets.token_hex(8)
    session_token = "onecap_sess_" + secrets.token_hex(8)
    request_path_base = f"/org/freedesktop/portal/desktop/request/{sender}"
    session_path = f"/org/freedesktop/portal/desktop/session/{sender}/{session_token}"

    loop = GLib.MainLoop()
    state = {"session": None, "fd": None, "node_id": None, "pipeline": None}

    def log(msg):
        print(f"[portal] {msg}", file=sys.stderr, flush=True)

    def handle_response(stage, then):
        req_path = f"{request_path_base}/{stage}"
        log(f"waiting response on {req_path}")
        def on_response(response, results):
            log(f"response stage={stage} code={response} results-keys={list(results.keys())}")
            if response != 0:
                print(f"portal stage {stage} failed: response={response}", file=sys.stderr)
                loop.quit()
                return
            try:
                then(results)
            except Exception as e:
                log(f"handler error: {e!r}")
                import traceback; traceback.print_exc()
                loop.quit()
        bus.add_signal_receiver(on_response,
            signal_name="Response",
            dbus_interface="org.freedesktop.portal.Request",
            path=req_path)

    # 1. CreateSession
    create_token = "onecap_req_" + secrets.token_hex(8)
    handle_response(create_token, lambda r: select_sources(r["session_handle"]))
    screencast.CreateSession({
        "handle_token": create_token,
        "session_handle_token": session_token,
    })

    def select_sources(session_handle):
        state["session"] = session_handle
        select_token = "onecap_req_" + secrets.token_hex(8)
        handle_response(select_token, lambda r: start_session(session_handle))
        screencast.SelectSources(session_handle, {
            "handle_token": select_token,
            "types": dbus.UInt32(1),         # 1 = MONITOR
            "multiple": False,
            "cursor_mode": dbus.UInt32(2),   # 2 = embedded
        })

    def start_session(session_handle):
        start_token = "onecap_req_" + secrets.token_hex(8)
        def on_started(results):
            streams = results.get("streams", [])
            if not streams:
                print("portal returned no streams", file=sys.stderr)
                loop.quit()
                return
            node_id = int(streams[0][0])
            fd = screencast.OpenPipeWireRemote(session_handle, {})
            fd_int = fd.take()
            state["fd"] = fd_int
            state["node_id"] = node_id
            launch_pipeline(fd_int, node_id)
        handle_response(start_token, on_started)
        screencast.Start(session_handle, "", {"handle_token": start_token})

    def launch_pipeline(fd, node_id):
        # Matroska container handles abrupt close better than mp4.
        # Container picked by extension:
        #   .webm → VP8 (sw) — only choice for true WebM, slower
        #   .mkv  → x264 ultrafast (sw) — much faster, no frame drops at 1440p30
        target_bps = bitrate_kbps * 1000
        if out_path.endswith(".webm"):
            enc = (
                f"vp8enc deadline=1000000 cpu-used=4 threads=4 "
                f"end-usage=vbr target-bitrate={target_bps} "
                f"keyframe-max-dist={framerate * 3} "
                f"! webmmux streamable=true"
            )
        else:
            enc = (
                f"x264enc speed-preset=ultrafast tune=zerolatency "
                f"bitrate={bitrate_kbps} key-int-max={framerate * 3} "
                f"byte-stream=true threads=0 "
                f"! matroskamux streamable=true"
            )
        # Big queues with leaky=downstream so pipewiresrc never blocks on the
        # encoder; if encoder genuinely can't keep up, drops happen at the
        # queue boundary rather than locking the source.
        pipeline_str = (
            f"pipewiresrc fd={fd} path={node_id} do-timestamp=true ! "
            f"queue max-size-buffers=200 max-size-time=0 max-size-bytes=0 leaky=downstream ! "
            f"videoconvert n-threads=4 ! videorate ! video/x-raw,framerate={framerate}/1 ! "
            f"queue max-size-buffers=200 max-size-time=0 max-size-bytes=0 leaky=downstream ! "
            f"{enc} ! "
            f"queue max-size-buffers=200 max-size-time=0 max-size-bytes=0 ! "
            f"filesink location={out_path} sync=false async=false"
        )
        pipeline = Gst.parse_launch(pipeline_str)
        state["pipeline"] = pipeline

        gst_bus = pipeline.get_bus()
        gst_bus.add_signal_watch()

        def on_message(_bus, msg):
            t = msg.type
            if t == Gst.MessageType.EOS:
                loop.quit()
            elif t == Gst.MessageType.ERROR:
                err, debug = msg.parse_error()
                print(f"gst error: {err.message} / {debug}", file=sys.stderr)
                loop.quit()
        gst_bus.connect("message", on_message)

        pipeline.set_state(Gst.State.PLAYING)
        # Signal readiness to parent
        print("PORTAL_READY", flush=True)

    def shutdown(*_):
        p = state["pipeline"]
        if p is not None:
            p.send_event(Gst.Event.new_eos())
            # bus will deliver EOS, on_message quits loop
            GLib.timeout_add_seconds(5, loop.quit)  # safety timeout
        else:
            loop.quit()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    loop.run()

    if state["pipeline"] is not None:
        state["pipeline"].set_state(Gst.State.NULL)


if __name__ == "__main__":
    main()
