mkdir steam\hotkey_api
..\..\..\..\XRCatTool.exe -dump -include "ego_debuglog/ui.xml" -in "out\hotkey_api" -out "steam\hotkey_api\subst_01.cat"
..\..\..\..\XRCatTool.exe -dump -exclude "ego_debuglog/ui.xml" -exclude "content.xml" -in "out\hotkey_api" -out "steam\hotkey_api\ext_01.cat"

set /p DUMMY=Hit ENTER to exit...
