#ifndef NATIVEMPV_H
#define NATIVEMPV_H

#include <QString>
#include <QVariant>
#include <QByteArray>
#include <clocale>
#include <mpv/client.h>

#include "QtHelper.h"

/*
 * mpv drawing straight into a native window, for the Windows shell.
 *
 * On the other platforms mpv renders through mpvqt's OpenGL render API into a
 * framebuffer that the Qt Quick scene graph then composites under the web page.
 * On Windows that put the video, the page and the scene graph through one
 * desktop OpenGL context, with Chromium's Direct3D output handed across to it
 * every frame -- and on integrated GPUs, AMD's above all, that was the lag.
 *
 * Here mpv is given the window itself (`wid`) and presents with its own
 * Direct3D 11 flip-model swapchain. WebView2 sits above it as a transparent
 * child window, and DWM puts the two together. The frames never pass through
 * Qt, and hardware-decoded ones never leave the GPU.
 *
 * The interface is the four calls PlayerComponent made on mpvqt's
 * MpvController -- mpv(), setProperty, getProperty, command -- with the same
 * semantics, so the player itself does not change.
 */
class NativeMpv
{
public:
  /*
   * Everything the VO needs has to be decided before mpv_initialize. mpvqt
   * initialised first and configured after, which only worked because its VO
   * did not own a window.
   */
  static NativeMpv* create(quintptr wid)
  {
    // mpv refuses to start unless numbers are parsed the C way.
    std::setlocale(LC_NUMERIC, "C");

    mpv_handle* h = mpv_create();
    if (!h)
      return nullptr;

    int64_t w = static_cast<int64_t>(wid);
    mpv_set_option(h, "wid", MPV_FORMAT_INT64, &w);

    auto opt = [h](const char* name, const char* value) { mpv_set_option_string(h, name, value); };
    opt("vo", "gpu-next");
    opt("gpu-api", "d3d11");
    // No vendor driver at all is still a picture: Windows' WARP rasteriser
    // stands in for the GPU, which the old OpenGL path could only do by
    // putting llvmpipe under everything.
    opt("d3d11-warp", "auto");
    // The page owns the keyboard, the mouse and the pointer. mpv's window is
    // underneath WebView2 and must never react to input on its own.
    opt("input-default-bindings", "no");
    opt("input-vo-keyboard", "no");
    opt("input-cursor", "no");
    opt("cursor-autohide", "no");
    opt("keepaspect-window", "no");
    opt("osc", "no");
    opt("load-scripts", "no");
    // Black window from the start, not just once a file is loaded, so there is
    // always something solid under the transparent page.
    opt("force-window", "yes");
    opt("background-color", "#000000");

    if (mpv_initialize(h) < 0)
    {
      mpv_terminate_destroy(h);
      return nullptr;
    }
    return new NativeMpv(h);
  }

  ~NativeMpv()
  {
    if (m_mpv)
    {
      mpv_set_wakeup_callback(m_mpv, nullptr, nullptr);
      mpv_terminate_destroy(m_mpv);
    }
  }

  mpv_handle* mpv() const { return m_mpv; }

  int setProperty(const QString& property, const QVariant& value)
  {
    return mpv::qt::set_property(m_mpv, property, value);
  }

  QVariant getProperty(const QString& property)
  {
    return mpv::qt::get_property(m_mpv, property);
  }

  QVariant command(const QVariant& params)
  {
    return mpv::qt::command(m_mpv, params);
  }

private:
  explicit NativeMpv(mpv_handle* h) : m_mpv(h) {}
  mpv_handle* m_mpv;
};

#endif // NATIVEMPV_H
