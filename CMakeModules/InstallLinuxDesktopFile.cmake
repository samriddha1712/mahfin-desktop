install (FILES ${CMAKE_SOURCE_DIR}/resources/meta/online.mahfin.Mahfin.desktop DESTINATION ${CMAKE_INSTALL_FULL_DATAROOTDIR}/applications)
install (FILES ${CMAKE_SOURCE_DIR}/resources/meta/online.mahfin.Mahfin.appdata.xml DESTINATION ${CMAKE_INSTALL_FULL_DATAROOTDIR}/metainfo)
install (FILES ${CMAKE_SOURCE_DIR}/resources/images/icon.svg DESTINATION ${CMAKE_INSTALL_FULL_DATAROOTDIR}/icons/hicolor/scalable/apps RENAME online.mahfin.Mahfin.svg)

# Fixed-size icons as well as the scalable one: GNOME and KDE both pick a raster
# at the exact size when one exists, and only fall back to rendering the SVG.
foreach(ICON_SIZE 32 48 64 128 256)
  install (FILES ${CMAKE_SOURCE_DIR}/resources/images/hicolor/icon_${ICON_SIZE}.png
           DESTINATION ${CMAKE_INSTALL_FULL_DATAROOTDIR}/icons/hicolor/${ICON_SIZE}x${ICON_SIZE}/apps
           RENAME online.mahfin.Mahfin.png)
endforeach()
