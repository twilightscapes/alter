# Third-party software

Alter bundles these tools unmodified. Each keeps its own license.

| Tool | Version | Location | License |
| --- | --- | --- | --- |
| [ExifTool](https://exiftool.org) by Phil Harvey | 13.59 | `Tools/exiftool` | Same terms as Perl itself (Artistic License or GPL) |
| [cwebp](https://developers.google.com/speed/webp) from libwebp | 1.4.0 | `Tools/cwebp` | BSD 3-Clause |

## Downloaded on demand

Not bundled. Alter fetches this the first time someone turns it on, from the
publisher's own release, pinned to one revision and checked against its
SHA-256, and runs the file as published (nothing converted or re-hosted).

| Model | Used by | Source | License |
| --- | --- | --- | --- |
| SFace (`face_recognition_sface_2021dec.onnx`) by OpenCV | Faces (`Core/Services/FaceModelStore.swift`) | [huggingface.co/opencv/face_recognition_sface](https://huggingface.co/opencv/face_recognition_sface) at revision `3d70824` | Apache License 2.0 |

Faces runs entirely on the Mac: Apple's Vision finds faces and their
landmarks, SFace turns each aligned face into 128 numbers, and nothing —
photo, face or fingerprint — leaves the machine.
