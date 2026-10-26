"""Create an iOS 16.4+ single-size app icon asset; no third-party packages."""
from pathlib import Path
import json
import shutil
root = Path(__file__).resolve().parent
catalog = root / 'Assets.xcassets'
icons = catalog / 'AppIcon.appiconset'
icons.mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / 'AppIcon.png', icons / 'AppIcon.png')
(catalog / 'Contents.json').write_text(json.dumps({'info':{'author':'xcode','version':1}}))
(icons / 'Contents.json').write_text(json.dumps({
    'images':[{'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'}],
    'info':{'author':'xcode','version':1}
}))
