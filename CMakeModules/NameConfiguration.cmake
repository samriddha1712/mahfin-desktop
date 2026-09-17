set(MAIN_TARGET MahfinDesktop)

# Output binary name
set(MAIN_NAME mahfin-desktop)

# Data directory name - also used for QCoreApplication::applicationName
# which determines QStandardPaths (cache, config, data dirs)
set(DATA_NAME mahfin-desktop)

if(APPLE)
  set(MAIN_NAME "Mahfin Desktop")
  set(DATA_NAME "Mahfin Desktop")
elseif(WIN32)
  set(MAIN_NAME "Mahfin Desktop")
  set(DATA_NAME "Mahfin Desktop")
endif()

configure_file(src/shared/Names.cpp.in src/shared/Names.cpp @ONLY)
