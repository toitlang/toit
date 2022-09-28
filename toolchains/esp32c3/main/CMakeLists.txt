idf_component_register(SRCS "main.c"
  INCLUDE_DIRS
  "."
)

add_prebuilt_library(vm "libtoit_vm.a"
    PRIV_REQUIRES
	app_update
	bootloader_support
	bt
	esp_adc_cal
	esp_common
	esp_eth
	esp_event
	esp_hw_support
	esp_netif
	esp_ringbuf
	esp_rom
	esp_system
	esp_timer
	esp_wifi
	heap
	log
	lwip
	nvs_flash
	spi_flash
	vfs
)

target_link_libraries(${COMPONENT_LIB} INTERFACE -Wl,--whole-archive vm -Wl,--no-whole-archive)
