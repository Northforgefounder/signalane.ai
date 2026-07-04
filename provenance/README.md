\# Signalane Provenance Snapshot



A small Windows tool for creating provenance sidecar records for files and folders.
===================================================================================

## License

This tool is released under the MIT License.

Reuse, modification, redistribution, and commercial use are permitted under the terms of the MIT License. Keep the license notice with redistributed copies or modified versions.

===================================================================================

The script records selected file states by generating SHA-256 hashes and writing `.provenance` sidecar files. These records can later be used to check whether a file has changed since the snapshot was taken.



\## What It Does



For each selected file, the tool records:



\- file name

\- full path

\- SHA-256 hash

\- file size

\- file modification time

\- snapshot time

\- host and user

\- verification command



\## How To Use



1\. Double-click the `.bat` launcher.

2\. When the window opens, enter the source file or source folder path.

3\. Enter the target folder path, or press Enter to write provenance files next to the source files.

4\. Enter file extensions if you want to limit the scan, or press Enter to include all files.

5\. Wait for the snapshot to finish.



The generated `.provenance` files are written next to the source files or into the selected target folder.

## Example Source Paths



Single file:



```text

F:\\your_folder\\example.md



