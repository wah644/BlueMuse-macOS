# GitHub name, description and discoverability

Suggested repository name: **bluemuse-macos**

Paste this into GitHub's **About → Description** field:

> macOS app to stream Muse EEG headsets via LSL (Lab Streaming Layer), with live graphs and one-click four-channel EEG streaming.

Suggested topics are in `.github/topics.txt`; the ready-to-copy description is in
`.github/repository-description.txt`. Those files do not configure GitHub automatically.
Set the About description and topics through GitHub after creating the repository.

GitHub searches can match repository names, descriptions, topics and README content.
The title and opening paragraph clearly identify macOS, Muse EEG and Lab Streaming
Layer. This helps people recognize the project; Google chooses its own search title,
snippet and ranking. No particular ranking or traffic level is guaranteed.

Keep downloads easy to find: attach the DMG, checksum and distribution manifest to
an actual GitHub Release. The automatic Source code ZIP/TAR files are not app installers.
Add a concise release description and a screenshot with synthetic/demo data. Preserve
upstream credits and the model/timing validation notes; avoid implying that untested
headsets or Intel runtime behavior have been physically verified.
