# Flutter's engine and the plugins in use (supabase_flutter, video_player,
# webview_flutter, image_picker, http) ship their own consumer-rules.pro
# inside their AARs, which R8 merges in automatically — nothing app-specific
# is needed here today. Add rules here if a future dependency's release
# build breaks with a ClassNotFoundException/NoSuchMethodError that a plain
# `flutter build apk --release` doesn't reproduce in debug.
