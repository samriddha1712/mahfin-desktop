// libmpv's C API, for Swift. The client API drives playback; the render API
// draws frames into the app's own OpenGL layer (see VideoLayer.swift), which is
// how libmpv is embedded on macOS now that window embedding is gone.
#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>
