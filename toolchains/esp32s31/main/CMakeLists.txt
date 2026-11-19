idf_component_register(SRCS "toit.c" "usb_console.c"
                       INCLUDE_DIRS ""
                       PRIV_REQUIRES esp_hw_support esp_ringbuf esp_system)
target_link_libraries(${COMPONENT_LIB} INTERFACE "-Wl,--wrap=_write_r")
