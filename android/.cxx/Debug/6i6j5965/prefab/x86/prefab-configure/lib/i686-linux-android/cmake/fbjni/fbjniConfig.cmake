if(NOT TARGET fbjni::fbjni)
add_library(fbjni::fbjni SHARED IMPORTED)
set_target_properties(fbjni::fbjni PROPERTIES
    IMPORTED_LOCATION "/Users/rodrigobertolotti/.gradle/caches/transforms-3/2b9d6b0569543331508a4ca012fd8e16/transformed/jetified-fbjni-0.3.0/prefab/modules/fbjni/libs/android.x86/libfbjni.so"
    INTERFACE_INCLUDE_DIRECTORIES "/Users/rodrigobertolotti/.gradle/caches/transforms-3/2b9d6b0569543331508a4ca012fd8e16/transformed/jetified-fbjni-0.3.0/prefab/modules/fbjni/include"
    INTERFACE_LINK_LIBRARIES ""
)
endif()

