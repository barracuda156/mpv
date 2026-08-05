osxbundle = custom_target('osxbundle',
    input: join_paths('mpv.app', 'Contents', 'Resources', 'icon.icns'),
    output: 'icon.icns.inc',
    command: [file2string, '@INPUT@', '@OUTPUT@', '@SOURCE_ROOT@'],
)
sources += osxbundle

# classic-format icns for pre-10.7 targets, where ImageIO cannot decode the
# modern PNG/ARGB entries (regenerate with gen-legacy-icns.py)
osxbundle_legacy = custom_target('osxbundle_legacy',
    input: 'icon-legacy.icns',
    output: 'icon-legacy.icns.inc',
    command: [file2string, '@INPUT@', '@OUTPUT@', '@SOURCE_ROOT@'],
)
sources += osxbundle_legacy
