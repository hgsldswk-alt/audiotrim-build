"""Render app and share-extension signing options without reading credentials."""
import os
from pathlib import Path
import plistlib
import sys

data = plistlib.loads(Path(__file__).with_name("ExportOptions.plist").read_bytes())
data["teamID"] = os.environ["TEAM_ID"]
app_id = os.environ.get("APP_ID", "com.hgsldswk.audiotrim")
defaults = data["provisioningProfiles"]
profiles = {app_id: os.environ.get("APP_PROFILE", "AudioTrim AppStore")}
share_id = f"{app_id}.share"
share_profile = os.environ.get("SHARE_PROFILE", defaults.get(share_id))
if share_profile:
    profiles[share_id] = share_profile
data["provisioningProfiles"] = profiles
sys.stdout.buffer.write(plistlib.dumps(data))
