# Playing music stored on the iPhone or iPad

The phone can play music that is on the phone itself, with no Mac and no server: a folder in the Files app (On My iPhone, iCloud
Drive, a USB drive plugged in with an adapter), and single files opened in Vespertine from another app.

## Using it

First screen › **Add a Folder from Files**, and choose the folder. It appears under **Your Folders**. The music stays where it is:
the app keeps a bookmark to the folder (on this device only) and reads the files from there. Nothing is copied or changed.

A folder is browsed and played with the same screens, queue, Keep on This Device and player as a Mac's library or an SMB share
(see [PHONE-SHARES.md](PHONE-SHARES.md) for what is played, what needs the Mac, and how covers are found: it is the same reader
and the same index). The differences:

- The folder is looked at every time it is opened and whenever the app comes back to the front. Only new and changed files are
  read. A file that was deleted is off the lists at the next look; one deleted in between says so when it is played and is taken
  off the lists there and then.
- If the folder can't be opened (iOS dropped the app's permission to it) the app says to choose the folder again, and Output and
  the banner have **Choose the Folder Again**. If it isn't there (a drive was pulled out, the folder was moved or renamed) the app
  says so and to plug the drive in. Either way the list of songs is kept, and so are favorites and the queue.
- Now Playing says **Folder** as the source.

## Single files

Music files (FLAC, ALAC, AAC, WAV, AIFF, MP3) can be opened in Vespertine from Files, the share sheet, Mail, AirDrop and other
apps. The file is copied into the app's own folder, listed under **Opened Files**, and played. The app's folder shows in Files
under On My iPhone › Vespertine: music can be put there directly, and deleting a file there removes it from the app.

A file the phone can't open by itself (DSD, APE, WavPack and the rest) is refused with an alert, not copied.

## Not yet seen on a real device

Everything above is covered by tests on real folders (`FolderFilesTests`), but not yet by a phone. Open questions for the bench
(row B14 in [IOS-AUDIO-BENCH.md](IOS-AUDIO-BENCH.md)): how iCloud Drive lists and downloads songs that are not on the phone when
they are read, and what iOS reports when a USB drive is pulled out mid-song.

## Where the code is

`Packages/VespertineRemoteKit/Sources/VespertineShare/FolderFiles.swift`: `FolderFiles` (a folder as the `ShareFiles` a share
is), `FolderAccess` (the bookmark and the permission), `SavedFolder`, `FolderShelf`, `OpenedFiles`. `ShareMac` answers the app
from it unchanged. In the app: `RemoteApp/Sources/Folders.swift` and the folder parts of `RemoteAppModel.swift`.
