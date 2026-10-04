#ifndef RUNNER_DOCUMENT_WINDOWS_H_
#define RUNNER_DOCUMENT_WINDOWS_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// The document windows' host: serves "planchette/windows" on the app's
// engine (the protocol is the library doc of lib/services/window_host.dart).
//
// Every extra window is a GTK window holding an FlView made for the app's
// running engine (fl_view_new_for_engine), so it renders in the same
// isolate as the main window and shares its state. Closing one only
// reports "closeRequested"; Dart drops the window's widgets and then asks
// for "destroy", which removes the view from the engine. A view can go
// without disposing an engine, so nothing here trips over the EGL display
// the windows share.
//
// The file pickers the app asks for belong to the window that asked, so a
// dialog never opens on the main window while another window made the
// request — and never on a hidden main window at all.
//
// Owned by [main_window]: the extra windows are destroyed with it, as the
// app quits.
void document_windows_install(GtkApplication* application,
                              GtkWindow* main_window,
                              FlView* main_view);

#endif  // RUNNER_DOCUMENT_WINDOWS_H_
