"""Первый заметный сдвиг картинки в видео между start и end (секунды) — печатает время минус lead.

Скрипт съёмки режет по нему видео: появление баннера, раскрытие приложения, открытие экрана операции.
region=top — смотреть только верхнюю полосу (баннеры уведомлений), остальное не считается.
region=bright — не сдвиг, а первый светлый кадр (фон приложения после раскрытия с главного экрана).
"""
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops, ImageStat

video, start, end = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
lead = float(sys.argv[4]) if len(sys.argv) > 4 else 0.35
region = sys.argv[5] if len(sys.argv) > 5 else "full"
# Порог: баннер — небольшое изменение, раскрытие приложения — почти весь кадр.
threshold = float(sys.argv[6]) if len(sys.argv) > 6 else 8
frame = os.path.join(tempfile.mkdtemp(), "f.png")
prev, t = None, start
while t < end:
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{t:.2f}", "-i", video, "-frames:v", "1", "-vf", "scale=150:-1", frame])
    image = Image.open(frame).convert("L")
    if region == "top":
        image = image.crop((0, 0, image.width, image.height * 18 // 100))
    # Первые кадры записи бывают чёрными — переход «чёрный → экран» не считается.
    if ImageStat.Stat(image).mean[0] < 15:
        prev, t = None, t + 0.1
        continue
    if region == "bright":
        if ImageStat.Stat(image).mean[0] > 200:
            print(f"{max(start, t - lead):.2f}")
            break
        t += 0.1
        continue
    if prev is not None and sum(ImageStat.Stat(ImageChops.difference(image, prev)).mean) > threshold:
        print(f"{max(start, t - lead):.2f}")
        break
    prev, t = image, t + 0.1
else:
    print(f"{start:.2f}")
