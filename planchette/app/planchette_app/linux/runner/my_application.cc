#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include <cstring>

#include "document_windows.h"
#include "flutter/generated_plugin_registrant.h"
#include "window_title.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* documents_channel;
  GPtrArray* pending_documents;
  gboolean documents_ready;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// The window a second launch raises: the most recently focused visible
// document window. gtk_application_get_windows lists the windows most
// recently focused first. A transient is a dialog, and a hidden window is
// one the user closed while other documents stayed open, so neither is
// raised.
static GtkWindow* visible_document_window(GtkApplication* application) {
  for (GList* cursor = gtk_application_get_windows(application);
       cursor != nullptr; cursor = cursor->next) {
    GtkWindow* window = GTK_WINDOW(cursor->data);
    if (gtk_window_get_transient_for(window) != nullptr ||
        !gtk_widget_get_visible(GTK_WIDGET(window))) {
      continue;
    }
    return window;
  }
  return nullptr;
}

// A forwarded launch's paths reach Dart as 'open' calls once the intake
// has answered 'ready'; earlier sends wait in the pending list the answer
// drains (the macOS handshake in AppDelegate.swift).
static void deliver_documents(MyApplication* self,
                              const gchar* const* documents, gsize count) {
  if (count == 0) {
    return;
  }
  if (self->documents_ready && self->documents_channel != nullptr) {
    g_autoptr(FlValue) arguments = fl_value_new_list();
    for (gsize i = 0; i < count; i++) {
      fl_value_append_take(arguments, fl_value_new_string(documents[i]));
    }
    fl_method_channel_invoke_method(self->documents_channel, "open",
                                    arguments, nullptr, nullptr, nullptr);
    return;
  }
  for (gsize i = 0; i < count; i++) {
    g_ptr_array_add(self->pending_documents, g_strdup(documents[i]));
  }
}

// One forwarded argument: relative paths resolve against the sender's
// working directory. A dash-led name is absolutized only when it exists
// there; otherwise it goes verbatim so Dart's _documentArguments keeps
// reading it as an option (`--` included).
static gchar* forwarded_argument(GApplicationCommandLine* command_line,
                                 const gchar* argument) {
  const gchar* cwd = g_application_command_line_get_cwd(command_line);
  if (cwd != nullptr && !g_path_is_absolute(argument)) {
    g_autofree gchar* path = g_build_filename(cwd, argument, nullptr);
    if (argument[0] != '-' || g_file_test(path, G_FILE_TEST_EXISTS)) {
      return g_steal_pointer(&path);
    }
  }
  return g_strdup(argument);
}

// Implements GApplication::command_line: a forwarded launch's argv.
static gint my_application_command_line(
    GApplication* application, GApplicationCommandLine* command_line) {
  MyApplication* self = MY_APPLICATION(application);
  g_auto(GStrv) arguments =
      g_application_command_line_get_arguments(command_line, nullptr);
  // This instance's own launch arrives here too, and Dart already has
  // those arguments as argv. Only a remote invocation is a forward; its
  // arguments can equal this launch's (the same file opened again), so
  // they are never compared.
  if (!g_application_command_line_get_is_remote(command_line) ||
      arguments == nullptr || arguments[0] == nullptr) {
    return 0;
  }
  g_autoptr(GPtrArray) documents =
      g_ptr_array_new_with_free_func(g_free);
  for (gchar** cursor = arguments + 1; *cursor != nullptr; cursor++) {
    g_ptr_array_add(documents, forwarded_argument(command_line, *cursor));
  }
  deliver_documents(self,
                    reinterpret_cast<const gchar* const*>(documents->pdata),
                    documents->len);
  return 0;
}

// Implements GApplication::open: the file manager's open request. No raise
// here: Dart raises the window that owns the files (or takes them), the
// same split as the macOS runner.
static void my_application_open(GApplication* application, GFile** files,
                                gint file_count, const gchar* hint) {
  MyApplication* self = MY_APPLICATION(application);
  g_autoptr(GPtrArray) documents =
      g_ptr_array_new_with_free_func(g_free);
  for (gint i = 0; i < file_count; i++) {
    // Only local paths open; a virtual location (trash://) has none.
    gchar* path = g_file_get_path(files[i]);
    if (path != nullptr) {
      g_ptr_array_add(documents, path);
    }
  }
  deliver_documents(self,
                    reinterpret_cast<const gchar* const*>(documents->pdata),
                    documents->len);
}

// Implements the Dart->native 'ready' call: marks the intake ready and
// answers with the forwards that queued before it.
static void documents_channel_method_call_cb(FlMethodChannel* channel,
                                             FlMethodCall* call,
                                             gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (strcmp(fl_method_call_get_name(call), "ready") != 0) {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
    return;
  }
  self->documents_ready = TRUE;
  g_autoptr(FlValue) pending = fl_value_new_list();
  for (guint i = 0; i < self->pending_documents->len; i++) {
    fl_value_append_take(
        pending, fl_value_new_string(static_cast<const gchar*>(
                     self->pending_documents->pdata[i])));
  }
  g_ptr_array_set_size(self->pending_documents, 0);
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(pending));
  fl_method_call_respond(call, response, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // A second launch, a forwarded open or command line activates the
  // running instance: raise a window instead of opening a second engine
  // over the same stores. Any window means the engine exists, also before
  // its first frame shows it, so only the first activation builds one.
  if (gtk_application_get_windows(GTK_APPLICATION(application)) != nullptr) {
    GtkWindow* visible =
        visible_document_window(GTK_APPLICATION(application));
    if (visible != nullptr) {
      gtk_window_present(visible);
    }
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Shared with the extra windows, which title themselves the same way.
  window_title_apply(window, "Planchette");

  // Match the runtime window options in desktop_window.dart so a window that
  // becomes visible before Dart resizes it already has the final geometry.
  gtk_window_set_default_size(window, 1080, 760);
  gtk_window_set_position(window, GTK_WIN_POS_CENTER);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#00000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // More document windows on this engine: planchette/windows.
  document_windows_install(GTK_APPLICATION(application), window, view);

  // File opens from forwarded launches: planchette/documents, the channel
  // macOS delivers on. The main view's messenger, as the engine runs Dart.
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->documents_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "planchette/documents", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->documents_channel, documents_channel_method_call_cb, self,
      nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  // Not handled here: GApplication goes on to forward the arguments to
  // the primary instance's command-line handler, which delivers the
  // document paths to Dart.
  return FALSE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_pointer(&self->pending_documents, g_ptr_array_unref);
  g_clear_object(&self->documents_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_APPLICATION_CLASS(klass)->open = my_application_open;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->pending_documents = g_ptr_array_new_with_free_func(g_free);
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_COMMAND_LINE |
                                         G_APPLICATION_HANDLES_OPEN,
                                     nullptr));
}
