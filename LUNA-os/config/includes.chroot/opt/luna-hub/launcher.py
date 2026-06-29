#!/usr/bin/env python3
import subprocess, time, gi
gi.require_version('Gtk', '3.0')
gi.require_version('WebKit2', '4.1')
from gi.repository import Gtk, WebKit2

subprocess.Popen(["python3", "/opt/luna-hub/backend.py"])
time.sleep(1.5)

win = Gtk.Window(title="Luna Hub")
win.set_default_size(420, 600)
win.connect("destroy", Gtk.main_quit)
webview = WebKit2.WebView()
webview.load_uri("http://127.0.0.1:5151/")
win.add(webview)
win.show_all()
Gtk.main()
