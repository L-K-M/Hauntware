#ifndef RUNNER_WINDOW_TITLE_H_
#define RUNNER_WINDOW_TITLE_H_

#include <gtk/gtk.h>

// Copied from Séance (app/seance_app/linux/runner/window_title.h;
// docs/SHARED.md): the flutter create title code, shared by both windows.
//
// Titles a window the way GNOME expects, and the same for every window the
// app opens: a header bar when running in GNOME, since that is the style its
// apps use and the setup most users have (e.g. Ubuntu desktop); a traditional
// title bar on X without GNOME, in case the window manager does more exotic
// layout, e.g. tiling. Wayland is assumed to take the header bar (may need
// changing if future cases occur).
void window_title_apply(GtkWindow* window, const char* title);

#endif  // RUNNER_WINDOW_TITLE_H_
