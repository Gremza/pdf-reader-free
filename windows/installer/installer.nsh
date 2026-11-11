; Thumbnails of PDF files in File Explorer while PDF Gremza opens them.
; pdfthumb.dll (built from pdfthumb.c) draws the first page with the PDF renderer of Windows,
; and File Explorer puts the app icon (TypeOverlay) small in the thumbnail's corner.
; It is registered on the app's file type ("PDF Document", the name in fileAssociations),
; so it is only used for PDFs that open with PDF Gremza.
;
; The DLL lives outside $INSTDIR: File Explorer keeps it loaded, and a loaded file in $INSTDIR
; would stop the uninstaller of an update. A changed DLL gets a new number (THUMB_DLL), so an
; update can install it even while the old one is still loaded.

!define THUMB_CLSID "{3C524D7A-F39E-4C72-A665-B12AE525F3C0}"
!define THUMB_DLL "pdfthumb-1.dll"
!define THUMB_DIR "$LOCALAPPDATA\PDF Gremza Thumbnails"
!define THUMB_PROGID "Software\Classes\PDF Document"
!define THUMBNAIL_HANDLER "{e357fccd-a995-4576-b01f-234630154e96}"

!macro customInstall
  CreateDirectory "${THUMB_DIR}"
  SetOverwrite try
  File "/oname=${THUMB_DIR}\${THUMB_DLL}" "${BUILD_RESOURCES_DIR}\pdfthumb.dll"
  SetOverwrite on

  ; Older numbers; one that is still loaded goes with a later update.
  FindFirst $R0 $R1 "${THUMB_DIR}\pdfthumb-*.dll"
  ${DoWhile} $R1 != ""
    ${If} $R1 != "${THUMB_DLL}"
      Delete "${THUMB_DIR}\$R1"
    ${EndIf}
    FindNext $R0 $R1
  ${Loop}
  FindClose $R0

  WriteRegStr SHELL_CONTEXT "Software\Classes\CLSID\${THUMB_CLSID}" "" "PDF Gremza Thumbnails"
  WriteRegStr SHELL_CONTEXT "Software\Classes\CLSID\${THUMB_CLSID}\InprocServer32" "" "${THUMB_DIR}\${THUMB_DLL}"
  WriteRegStr SHELL_CONTEXT "Software\Classes\CLSID\${THUMB_CLSID}\InprocServer32" "ThreadingModel" "Apartment"
  WriteRegStr SHELL_CONTEXT "${THUMB_PROGID}\ShellEx\${THUMBNAIL_HANDLER}" "" "${THUMB_CLSID}"
  WriteRegStr SHELL_CONTEXT "${THUMB_PROGID}" "TypeOverlay" "$appExe,0"
  System::Call "shell32::SHChangeNotify(i 0x08000000, i 0x1000, p 0, p 0)"
!macroend

; An update runs the old uninstaller first; the new installer registers everything again.
!macro customUnInstall
  ${IfNot} ${isUpdated}
    DeleteRegKey SHELL_CONTEXT "Software\Classes\CLSID\${THUMB_CLSID}"
    Delete "${THUMB_DIR}\pdfthumb-*.dll"
    RMDir "${THUMB_DIR}"
  ${EndIf}
!macroend
