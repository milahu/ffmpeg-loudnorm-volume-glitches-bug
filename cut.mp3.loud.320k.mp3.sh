ffmpeg -i cut.mp3 -af loudnorm=i=-14.0:lra=7.0:tp=-2.0:linear=true:measured_i=-24.26:measured_lra=3.20:measured_tp=-3.18:measured_thresh=-34.57:offset=1.64 -b:a 320k cut.mp3.loud.320k.mp3
