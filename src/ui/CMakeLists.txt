find_all_sources(. UI_SRCS)
if(MAHFIN_NATIVE_SHELL)
  # The QML shell's window, and the two pieces that only exist for QtWebEngine:
  # its notification presenter and the key filter on its QQuickWindow.
  list(FILTER UI_SRCS EXCLUDE REGEX "(EventFilter|NotificationPresenter)\.(cpp|h)$")
  add_sources(${UI_SRCS})
  find_all_sources(win WIN_UI_SRCS)
  add_sources(${WIN_UI_SRCS})
else()
  add_sources(${UI_SRCS} webview.qml)
endif()
