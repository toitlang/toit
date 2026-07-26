// Copyright (C) 2026 Toit contributors.

// PLAT keep-list: the API surface the base guarantees to VM slots.
//
// The base is flashed once and slots are OTA'd against it, so a slot can
// only call PLAT functions that are LINKED INTO the base image. The VM's
// references do not participate in the separate base link, so this table
// keeps exactly the base symbols used by the current supported slot. A new
// dependency fails the slot link and must be reviewed explicitly instead of
// silently expanding a speculative base ABI.
//
// Referencing a symbol's address pulls its object out of the prebuilt
// archives past --gc-sections; the array itself costs 4 bytes of rodata
// per entry. The declarations are address-only, so the signatures are
// deliberately untyped.

// The base build defines sprintf=sprintf_ (and friends) globally to route
// ITS OWN calls to the PLAT variants; this table must reference the real
// newlib symbols the VM links against.
#undef sprintf
#undef snprintf
#undef vsnprintf

// The untyped declarations clash with GCC's builtin prototypes for the
// libc/libm entries (memcpy, sqrt, ...) — harmless here, addresses only.
#pragma GCC diagnostic ignored "-Wbuiltin-declaration-mismatch"

// CMSIS driver ACCESS STRUCTS (data, not functions): the VM binds to these
// directly. The base's own code only references some of them, so the rest
// must be kept explicitly.
extern void Driver_I2C0(void);
extern void Driver_I2C1(void);
extern void Driver_USART0(void);
extern void Driver_USART1(void);
extern void Driver_USART2(void);
extern void ADC_channelDeInit(void);
extern void ADC_channelInit(void);
extern void ADC_getDefaultConfig(void);
extern void ADC_startConversion(void);
extern void BSP_QSPI_Erase_Safe(void);
extern void BSP_QSPI_Write_Safe(void);
extern void BSP_SetPlatConfigItemValue(void);
extern void CLOCK_clockEnable(void);
extern void CLOCK_setClockDiv(void);
extern void CLOCK_setClockSrc(void);
extern void GPIO_IomuxEC618(void);
extern void GPIO_PullConfig(void);
extern void GPIO_WakeupPadConfig(void);
extern void GPIO_clearInterruptFlags(void);
extern void GPIO_getInterruptFlags(void);
extern void GPIO_interruptConfig(void);
extern void GPIO_pinConfig(void);
extern void GPIO_pinRead(void);
extern void GPIO_pinWrite(void);
extern void GPR_setClockDiv(void);
extern void GPR_setClockSrc(void);
extern void GPR_swReset(void);
extern void GPR_swResetModule(void);
extern void HAL_ADC_CalibrateRawCode(void);
extern void OsaSystemTimeReadRamUtc(void);
extern void OsaTimerSync(void);
extern void PAD_setPinPullConfig(void);
extern void ResetStateGet(void);
extern void SPI_BlockTransfer(void);
extern void SPI_MasterInit(void);
extern void SPI_SetCallbackFun(void);
extern void SPI_SetNewConfig(void);
extern void SPI_SetNoBlock(void);
extern void SPI_TransferEx(void);
extern void SPI_TransferStop(void);
extern void TIMER_driverInit(void);
extern void TIMER_start(void);
extern void TIMER_stop(void);
extern void WDT_deInit(void);
extern void WDT_init(void);
extern void WDT_kick(void);
extern void WDT_start(void);
extern void WDT_stop(void);
extern void XIC_EnableIRQ(void);
extern void XIC_SetVector(void);
extern void _ZSt25__throw_bad_function_callv(void);
extern void _ZdaPv(void);
extern void _ZdlPv(void);
// Keep only the C++ runtime helpers referenced by the current slot. Do not
// add speculative helpers for a future compiler version.
extern void __aeabi_atexit(void);
extern void __aeabi_d2f(void);
extern void __aeabi_d2iz(void);
extern void __aeabi_d2lz(void);
extern void __aeabi_d2uiz(void);
extern void __aeabi_dadd(void);
extern void __aeabi_dcmpeq(void);
extern void __aeabi_dcmpge(void);
extern void __aeabi_dcmpgt(void);
extern void __aeabi_dcmple(void);
extern void __aeabi_dcmplt(void);
extern void __aeabi_dcmpun(void);
extern void __aeabi_ddiv(void);
extern void __aeabi_dmul(void);
extern void __aeabi_dsub(void);
extern void __aeabi_f2d(void);
extern void __aeabi_i2d(void);
extern void __aeabi_l2d(void);
extern void __aeabi_ldivmod(void);
extern void __aeabi_ui2d(void);
extern void __aeabi_uldivmod(void);
extern void __assert_func(void);
extern void __popcountdi2(void);
extern void __popcountsi2(void);
extern void abort(void);
extern void acos(void);
extern void aligned_alloc(void);
extern void apmuSetDeepestSleepMode(void);
extern void appGetECBCInfoSync(void);
extern void appSetCFUN(void);
extern void asin(void);
extern void atan(void);
extern void atan2(void);
extern void calloc(void);
extern void ceil(void);
extern void cos(void);
extern void cosh(void);
extern void delay_us(void);
extern void deregisterPSEventCallback(void);
extern void exp(void);
extern void fflush(void);
extern void floor(void);
extern void fmod(void);
extern void fotaNvmNfsPeInit(void);
extern void fputc(void);
extern void fputs(void);
extern void free(void);
extern void fwrite(void);
extern void gmtime_r(void);
extern void isspace(void);
extern void localtime_r(void);
extern void log(void);
extern void malloc(void);
extern void memchr(void);
extern void memcmp(void);
extern void memcpy(void);
extern void memmove(void);
extern void memset(void);
extern void mktime(void);
extern void osDelay(void);
extern void osKernelGetTickCount(void);
extern void pbuf_alloc(void);
extern void pbuf_cat(void);
extern void pbuf_free(void);
extern void pbuf_ref(void);
extern void pow(void);
extern void printf(void);
extern void psSetCdgcont(void);
extern void putchar(void);
extern void putenv(void);
extern void puts(void);
extern void realloc(void);
extern void registerPSEventCallback(void);
extern void rngGenRandom(void);
extern void round(void);
extern void sin(void);
extern void sinh(void);
extern void anchor_console_for_slot(void);
extern void anchor_read(void);
extern void anchor_rollback(void);
extern void anchor_set_pending_console(void);
extern void anchor_stage(void);
extern void anchor_table_for_slot(void);
extern void anchor_validate(void);
// The RTC-backed libc time shim is referenced only by slot code. Without a
// keep entry the base link garbage-collects the definition that the slot's
// --wrap flag relies on.
extern void __wrap_time(void);
extern void slpManAONIOPowerOff(void);
extern void slpManAONIOPowerOn(void);
extern void slpManAONIOVoltSet(void);
extern void slpManAonWdtStop(void);
extern void slpManApplyPlatVoteHandle(void);
extern void slpManDeepSlpTimerRegisterExpCb(void);
extern void slpManDeepSlpTimerStart(void);
extern void slpManDrvVoteSleep(void);
extern void slpManGetLastSlpState(void);
extern void slpManGetWakeupPadCfg(void);
extern void slpManGetWakeupPinValue(void);
extern void slpManGetWakeupSrc(void);
extern void slpManPlatGetSlpState(void);
extern void slpManPlatVoteDisableSleep(void);
extern void slpManPlatVoteEnableSleep(void);
extern void slpManSetPmuSleepMode(void);
extern void slpManSetWakeupPadCfg(void);
extern void snprintf(void);
extern void soc_power_mode(void);
extern void sprintf(void);
extern void sqrt(void);
extern void strchr(void);
extern void strcmp(void);
extern void strcpy(void);
extern void strlen(void);
extern void strncmp(void);
extern void strncpy(void);
extern void strstr(void);
extern void strtod(void);
extern void tan(void);
extern void tanh(void);
extern void tcp_accept(void);
extern void tcp_arg(void);
extern void tcp_bind(void);
extern void tcp_close(void);
extern void tcp_connect(void);
extern void tcp_err(void);
extern void tcp_listen_with_backlog(void);
extern void tcp_new(void);
extern void tcp_output(void);
extern void tcp_recv(void);
extern void tcp_recved(void);
extern void tcp_sent(void);
extern void tcp_shutdown(void);
extern void tcp_write(void);
extern void tcpip_callback_with_block(void);
extern void trimAdcSetGolbalVar(void);
extern void trunc(void);
extern void tzset(void);
extern void udp_bind(void);
extern void udp_connect(void);
extern void udp_new(void);
extern void udp_recv(void);
extern void udp_remove(void);
extern void udp_send(void);
extern void udp_sendto(void);
extern void vPortGetHeapStats(void);
extern void vPortGetHeapTag(void);
extern void vPortIterateAllocations(void);
extern void vPortSetHeapTag(void);
extern void vQueueDelete(void);
extern void vTaskDelete(void);
extern void vfprintf(void);
extern void xQueueCreateMutex(void);
extern void xQueueGenericCreate(void);
extern void xQueueGenericReceive(void);
extern void xQueueGenericSend(void);
extern void xQueueGenericSendFromISR(void);
extern void xQueueGetMutexHolder(void);
extern void xTaskCreate(void);
extern void xTaskGetCurrentTaskHandle(void);

__attribute__((used, section(".rodata.toit_plat_keep")))
const void* const toit_plat_keep[] = {
  (const void*)&Driver_I2C0,
  (const void*)&Driver_I2C1,
  (const void*)&Driver_USART0,
  (const void*)&Driver_USART1,
  (const void*)&Driver_USART2,
  (const void*)&ADC_channelDeInit,
  (const void*)&ADC_channelInit,
  (const void*)&ADC_getDefaultConfig,
  (const void*)&ADC_startConversion,
  (const void*)&BSP_QSPI_Erase_Safe,
  (const void*)&BSP_QSPI_Write_Safe,
  (const void*)&BSP_SetPlatConfigItemValue,
  (const void*)&CLOCK_clockEnable,
  (const void*)&CLOCK_setClockDiv,
  (const void*)&CLOCK_setClockSrc,
  (const void*)&GPIO_IomuxEC618,
  (const void*)&GPIO_PullConfig,
  (const void*)&GPIO_WakeupPadConfig,
  (const void*)&GPIO_clearInterruptFlags,
  (const void*)&GPIO_getInterruptFlags,
  (const void*)&GPIO_interruptConfig,
  (const void*)&GPIO_pinConfig,
  (const void*)&GPIO_pinRead,
  (const void*)&GPIO_pinWrite,
  (const void*)&GPR_setClockDiv,
  (const void*)&GPR_setClockSrc,
  (const void*)&GPR_swReset,
  (const void*)&GPR_swResetModule,
  (const void*)&HAL_ADC_CalibrateRawCode,
  (const void*)&OsaSystemTimeReadRamUtc,
  (const void*)&OsaTimerSync,
  (const void*)&PAD_setPinPullConfig,
  (const void*)&ResetStateGet,
  (const void*)&SPI_BlockTransfer,
  (const void*)&SPI_MasterInit,
  (const void*)&SPI_SetCallbackFun,
  (const void*)&SPI_SetNewConfig,
  (const void*)&SPI_SetNoBlock,
  (const void*)&SPI_TransferEx,
  (const void*)&SPI_TransferStop,
  (const void*)&TIMER_driverInit,
  (const void*)&TIMER_start,
  (const void*)&TIMER_stop,
  (const void*)&WDT_deInit,
  (const void*)&WDT_init,
  (const void*)&WDT_kick,
  (const void*)&WDT_start,
  (const void*)&WDT_stop,
  (const void*)&XIC_EnableIRQ,
  (const void*)&XIC_SetVector,
  (const void*)&_ZSt25__throw_bad_function_callv,
  (const void*)&_ZdaPv,
  (const void*)&_ZdlPv,
  (const void*)&__aeabi_atexit,
  (const void*)&__aeabi_d2f,
  (const void*)&__aeabi_d2iz,
  (const void*)&__aeabi_d2lz,
  (const void*)&__aeabi_d2uiz,
  (const void*)&__aeabi_dadd,
  (const void*)&__aeabi_dcmpeq,
  (const void*)&__aeabi_dcmpge,
  (const void*)&__aeabi_dcmpgt,
  (const void*)&__aeabi_dcmple,
  (const void*)&__aeabi_dcmplt,
  (const void*)&__aeabi_dcmpun,
  (const void*)&__aeabi_ddiv,
  (const void*)&__aeabi_dmul,
  (const void*)&__aeabi_dsub,
  (const void*)&__aeabi_f2d,
  (const void*)&__aeabi_i2d,
  (const void*)&__aeabi_l2d,
  (const void*)&__aeabi_ldivmod,
  (const void*)&__aeabi_ui2d,
  (const void*)&__aeabi_uldivmod,
  (const void*)&__assert_func,
  (const void*)&__popcountdi2,
  (const void*)&__popcountsi2,
  (const void*)&abort,
  (const void*)&acos,
  (const void*)&aligned_alloc,
  (const void*)&apmuSetDeepestSleepMode,
  (const void*)&appGetECBCInfoSync,
  (const void*)&appSetCFUN,
  (const void*)&asin,
  (const void*)&atan,
  (const void*)&atan2,
  (const void*)&calloc,
  (const void*)&ceil,
  (const void*)&cos,
  (const void*)&cosh,
  (const void*)&delay_us,
  (const void*)&deregisterPSEventCallback,
  (const void*)&exp,
  (const void*)&fflush,
  (const void*)&floor,
  (const void*)&fmod,
  (const void*)&fotaNvmNfsPeInit,
  (const void*)&fputc,
  (const void*)&fputs,
  (const void*)&free,
  (const void*)&fwrite,
  (const void*)&gmtime_r,
  (const void*)&isspace,
  (const void*)&localtime_r,
  (const void*)&log,
  (const void*)&malloc,
  (const void*)&memchr,
  (const void*)&memcmp,
  (const void*)&memcpy,
  (const void*)&memmove,
  (const void*)&memset,
  (const void*)&mktime,
  (const void*)&osDelay,
  (const void*)&osKernelGetTickCount,
  (const void*)&pbuf_alloc,
  (const void*)&pbuf_cat,
  (const void*)&pbuf_free,
  (const void*)&pbuf_ref,
  (const void*)&pow,
  (const void*)&printf,
  (const void*)&psSetCdgcont,
  (const void*)&putchar,
  (const void*)&putenv,
  (const void*)&puts,
  (const void*)&realloc,
  (const void*)&registerPSEventCallback,
  (const void*)&rngGenRandom,
  (const void*)&round,
  (const void*)&sin,
  (const void*)&sinh,
  (const void*)&anchor_console_for_slot,
  (const void*)&anchor_read,
  (const void*)&anchor_rollback,
  (const void*)&anchor_set_pending_console,
  (const void*)&anchor_stage,
  (const void*)&anchor_table_for_slot,
  (const void*)&anchor_validate,
  (const void*)&__wrap_time,
  (const void*)&slpManAONIOPowerOff,
  (const void*)&slpManAONIOPowerOn,
  (const void*)&slpManAONIOVoltSet,
  (const void*)&slpManAonWdtStop,
  (const void*)&slpManApplyPlatVoteHandle,
  (const void*)&slpManDeepSlpTimerRegisterExpCb,
  (const void*)&slpManDeepSlpTimerStart,
  (const void*)&slpManDrvVoteSleep,
  (const void*)&slpManGetLastSlpState,
  (const void*)&slpManGetWakeupPadCfg,
  (const void*)&slpManGetWakeupPinValue,
  (const void*)&slpManGetWakeupSrc,
  (const void*)&slpManPlatGetSlpState,
  (const void*)&slpManPlatVoteDisableSleep,
  (const void*)&slpManPlatVoteEnableSleep,
  (const void*)&slpManSetPmuSleepMode,
  (const void*)&slpManSetWakeupPadCfg,
  (const void*)&snprintf,
  (const void*)&soc_power_mode,
  (const void*)&sprintf,
  (const void*)&sqrt,
  (const void*)&strchr,
  (const void*)&strcmp,
  (const void*)&strcpy,
  (const void*)&strlen,
  (const void*)&strncmp,
  (const void*)&strncpy,
  (const void*)&strstr,
  (const void*)&strtod,
  (const void*)&tan,
  (const void*)&tanh,
  (const void*)&tcp_accept,
  (const void*)&tcp_arg,
  (const void*)&tcp_bind,
  (const void*)&tcp_close,
  (const void*)&tcp_connect,
  (const void*)&tcp_err,
  (const void*)&tcp_listen_with_backlog,
  (const void*)&tcp_new,
  (const void*)&tcp_output,
  (const void*)&tcp_recv,
  (const void*)&tcp_recved,
  (const void*)&tcp_sent,
  (const void*)&tcp_shutdown,
  (const void*)&tcp_write,
  (const void*)&tcpip_callback_with_block,
  (const void*)&trimAdcSetGolbalVar,
  (const void*)&trunc,
  (const void*)&tzset,
  (const void*)&udp_bind,
  (const void*)&udp_connect,
  (const void*)&udp_new,
  (const void*)&udp_recv,
  (const void*)&udp_remove,
  (const void*)&udp_send,
  (const void*)&udp_sendto,
  (const void*)&vPortGetHeapStats,
  (const void*)&vPortGetHeapTag,
  (const void*)&vPortIterateAllocations,
  (const void*)&vPortSetHeapTag,
  (const void*)&vQueueDelete,
  (const void*)&vTaskDelete,
  (const void*)&vfprintf,
  (const void*)&xQueueCreateMutex,
  (const void*)&xQueueGenericCreate,
  (const void*)&xQueueGenericReceive,
  (const void*)&xQueueGenericSend,
  (const void*)&xQueueGenericSendFromISR,
  (const void*)&xQueueGetMutexHolder,
  (const void*)&xTaskCreate,
  (const void*)&xTaskGetCurrentTaskHandle,
};
