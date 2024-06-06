if(NOT TARGET fbjni::fbjni)
add_library(fbjni::fbjni SHARED IMPORTED)
set_target_properties(fbjni::fbjni PROPERTIES
    IMPORTED_LOCATION "/Users/rodrigobertolotti/.gradle/caches/transforms-3/62f2e0a30b5014e20f3aa5fac3e0769a/transformed/jetified-fbjni-0.3.0/prefab/modules/fbjni/libs/android.arm64-v8a/libfbjni.so"
    INTERFACE_INCLUDE_DIRECTORIES "/Users/rodrigobertolotti/.gradle/caches/transforms-3/62f2e0a30b5014e20f3aa5fac3e0769a/transformed/jetified-fbjni-0.3.0/prefab/modules/fbjni/include"
    INTERFACE_LINK_LIBRARIES ""
)
endif()

