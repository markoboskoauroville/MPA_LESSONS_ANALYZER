# make_icon.py: MPA Lessons Analyzer icon (a frame drum with a lesson line). python3 make_icon.py
import os, subprocess
from PIL import Image, ImageDraw, ImageFont
S=1024
img=Image.new("RGBA",(S,S),(0,0,0,0))
t=Image.new("L",(S,S),0); ImageDraw.Draw(t).rounded_rectangle((100,100,924,924),radius=185,fill=255)
img.paste(Image.new("RGBA",(S,S),(22,18,14,255)),(0,0),t)
d=ImageDraw.Draw(img)
d.ellipse((232,200,792,760),fill=(196,140,80,255)); d.ellipse((262,230,762,730),fill=(236,214,176,255))
for i,h in enumerate((90,200,140,260,110)):
    x=330+i*90; d.rounded_rectangle((x,480-h//2,x+36,480+h//2),radius=18,fill=(30,24,18,255))
F="/System/Library/Fonts/SFNSRounded.ttf"
if not os.path.exists(F): F="/System/Library/Fonts/Helvetica.ttc"
d.text((S/2,845),"MPA",font=ImageFont.truetype(F,120),fill=(236,214,176,255),anchor="mm")
img.save("icon_1024.png")
os.makedirs("AppIcon.iconset",exist_ok=True)
for s in (16,32,128,256,512):
    img.resize((s,s),Image.LANCZOS).save(f"AppIcon.iconset/icon_{s}x{s}.png")
    img.resize((s*2,s*2),Image.LANCZOS).save(f"AppIcon.iconset/icon_{s}x{s}@2x.png")
subprocess.run(["iconutil","-c","icns","AppIcon.iconset","-o","AppIcon.icns"],check=True)
import shutil; shutil.rmtree("AppIcon.iconset")
