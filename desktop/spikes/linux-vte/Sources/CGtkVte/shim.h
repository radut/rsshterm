#include <gtk/gtk.h>
#include <vte/vte.h>

// GTK's cast macros (GTK_WINDOW, VTE_TERMINAL, ...) and g_signal_connect are macros Swift cannot import.
static inline GtkWindow *spike_window(GtkWidget *w) { return GTK_WINDOW(w); }
static inline GApplication *spike_app(GtkApplication *a) { return G_APPLICATION(a); }
static inline VteTerminal *spike_terminal(GtkWidget *w) { return VTE_TERMINAL(w); }
static inline gulong spike_connect(gpointer instance, const char *signal, GCallback cb, gpointer data) {
    return g_signal_connect_data(instance, signal, cb, data, NULL, 0);
}
