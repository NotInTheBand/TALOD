-- TALOD - the release this copy knows of, signed with the author's key, and
-- the public half of that key. Written by tools/release_sign.py (keygen, once).
-- The note stays nil here: only the copy inside a release zip is signed, by
-- hand at upload time. Never edit by hand.
--
-- The note is "<name>|<version>|<date>". It says that version is out; it is
-- passed on to other copies over the version channel (Version.lua), which
-- check the signature (Signature.lua). The public key checks signatures and
-- cannot make them.

local ADDON_NAME, ns = ...

ns.RELEASE_KEY = { bytes = 128, n = "ada44bc50859ca74a2f52379f1f67a93f215c586232f4cbba2d6c406730804630366b23d6bb723841b6ba7c2d4e009f27a91d61003b016b59896fa55d907a22732b84105398cfaa3b64508877277f30c2ab81da7178dee1c52f6a6bf735bee3c86a3e807e4bb43bfa06e1f5e5188c07b792e905291140575dc7a4f3a1e246dd1", r2 = "8b54616af6ec0081cad7f0d0067d0635822c0c3a4e6cd19bfd733894db02fe5738595d95f042e52a9789d537b4ff2b05b4d2fae13bc6927ee61cd4f07cf0a5dd499d1e473d58b01d01bbe1b796063e6de647656001bcee0ca43e24c6a3b2fff8e0746d4afdac138099dd6557013799ba3165774de9f3495ce5aa70a10de3c106", ninv = 14742735 }
ns.RELEASE_NOTE = nil
