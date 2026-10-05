add_sources(
  ComponentManager.cpp ComponentManager.h
  ProfileManager.cpp ProfileManager.h
  Version.h
)
if(NOT MAHFIN_NATIVE_SHELL)
  # The QML engine and its window.
  add_sources(Globals.cpp Globals.h)
endif()

if(UNIX)
  add_sources(SignalManager.cpp SignalManager.h)
endif()
