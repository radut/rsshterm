// gtk4 + libadwaita-1 + vte-2.91-gtk4 for Swift. vte's pkg-config brings gtk4's include path; libadwaita's headers
// include each other with quotes, so <libadwaita-1/adwaita.h> works without its own -I.
#include <gtk/gtk.h>
#include <libadwaita-1/adwaita.h>
#include <vte/vte.h>
#include <glib-unix.h>
