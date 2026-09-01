// E3 app: a real GTK program, static-musl, cross-linked against our cross-built GTK3 toolkit.
// Verified: links to a 100MB static ELF and RUNS (prints GTK 3.24.52, gtk_window_new OK).
#include <gtk/gtk.h>
#include <stdio.h>
int main(int argc, char** argv)
{
    printf("[e3] GTK %d.%d.%d\n", GTK_MAJOR_VERSION, GTK_MINOR_VERSION, GTK_MICRO_VERSION);
    gtk_init(&argc, &argv);
    GtkWidget* w = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    if (w) printf("[e3] gtk_window_new OK (%p)\n", (void*)w);
    return 0;
}