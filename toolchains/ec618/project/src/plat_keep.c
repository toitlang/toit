// Copyright (C) 2026 Toit contributors.

// PLAT keep-list: the API surface the base guarantees to future VM slots.
//
// The base is flashed once and slots are OTA'd against it, so a slot can
// only call PLAT functions that are LINKED INTO the base image. The VM's
// own references keep the currently-used set alive; this table keeps the
// GENEROUS surface alive too — PLAT/libc/libm/libgcc functions a future
// firmware is likely to need that the current image happens not to call.
// It carries forward the previously exported symbol surface, so no
// capability was lost in the switch to direct calls.
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
extern void ARM_I2C_GetVersion(void);
extern void ARM_USART_GetVersion(void);
extern void BSP_CommonInit(void);
extern void BSP_CustomInit(void);
extern void BSP_DeInit_SmallImg(void);
extern void BSP_FlashNVICSwReset(void);
extern void BSP_FlashSetGvarforSlp2(void);
extern void BSP_GetFSAssertCount(void);
extern void BSP_GetPlatConfigItemValue(void);
extern void BSP_GetRawFlashPlatConfig(void);
extern void BSP_Init_SmallImg(void);
extern void BSP_LoadPlatConfigFromFs(void);
extern void BSP_LoadPlatConfigFromRawFlash(void);
extern void BSP_QSPI_Erase_Cmd(void);
extern void BSP_QSPI_Erase_Proc(void);
extern void BSP_QSPI_Erase_Safe(void);
extern void BSP_QSPI_Erase_Sector(void);
extern void BSP_QSPI_Init(void);
extern void BSP_QSPI_Read_Safe(void);
extern void BSP_QSPI_Read_Status_Reg(void);
extern void BSP_QSPI_SWReset(void);
extern void BSP_QSPI_Write(void);
extern void BSP_QSPI_Write_Gran_Cmd(void);
extern void BSP_QSPI_Write_Proc(void);
extern void BSP_QSPI_Write_Safe(void);
extern void BSP_QSPI_Write_Volatile_Status_Reg(void);
extern void BSP_QSPI_XIP_Mode_Disable(void);
extern void BSP_QSPI_XIP_Mode_Enable(void);
extern void BSP_SavePlatConfigToFs(void);
extern void BSP_SavePlatConfigToRawFlash(void);
extern void BSP_SetFSAssertCount(void);
extern void BSP_SetFsPorDefaultValue(void);
extern void BSP_SetPlatConfigItemValue(void);
extern void BSP_UsbDeInit(void);
extern void BSP_UsbInit(void);
extern void CLOCK_AssertChkBeforeSlp(void);
extern void CLOCK_Trace(void);
extern void CLOCK_checkClkID(void);
extern void CLOCK_clockDisable(void);
extern void CLOCK_clockEnable(void);
extern void CLOCK_clockReset(void);
extern void CLOCK_getClockFreq(void);
extern void CLOCK_setClockDiv(void);
extern void CLOCK_setClockSrc(void);
extern void DMA_ForceStartStream(void);
extern void DMA_buildDescriptor(void);
extern void DMA_closeChannel(void);
extern void DMA_disableChannelInterrupts(void);
extern void DMA_enableChannelInterrupts(void);
extern void DMA_getChannelCount(void);
extern void DMA_getChannelCurrentTargetAddress(void);
extern void DMA_init(void);
extern void DMA_loadChannelDescriptorAndRun(void);
extern void DMA_loadChannelFirstDescriptor(void);
extern void DMA_openChannel(void);
extern void DMA_resetChannel(void);
extern void DMA_resumeChannel(void);
extern void DMA_rigisterChannelCallback(void);
extern void DMA_setChannelRequestSource(void);
extern void DMA_setDescriptorTransferLen(void);
extern void DMA_startChannel(void);
extern void DMA_stopChannel(void);
extern void DMA_stopChannelNoWait(void);
extern void DMA_suspendChannel(void);
extern void DMA_transferSetup(void);
extern void GPIO_Config(void);
extern void GPIO_EnterLowPowerStatePrepare(void);
extern void GPIO_ExitLowPowerStateRestore(void);
extern void GPIO_ExtiConfig(void);
extern void GPIO_ExtiSetCB(void);
extern void GPIO_FastOutput(void);
extern void GPIO_GlobalInit(void);
extern void GPIO_Input(void);
extern void GPIO_InputMulti(void);
extern void GPIO_IomuxEC618(void);
extern void GPIO_OutPulse(void);
extern void GPIO_Output(void);
extern void GPIO_OutputMulti(void);
extern void GPIO_PullConfig(void);
extern void GPIO_ToPadEC618(void);
extern void GPIO_Toggle(void);
extern void GPIO_ToggleMulti(void);
extern void GPIO_WakeupPadConfig(void);
extern void GPIO_clearInterruptFlags(void);
extern void GPIO_driverInit(void);
extern void GPIO_enterLowPowerStatePrepare(void);
extern void GPIO_exitLowPowerStateRestore(void);
extern void GPIO_getInterruptFlags(void);
extern void GPIO_interruptConfig(void);
extern void GPIO_pinConfig(void);
extern void GPIO_pinRead(void);
extern void GPIO_pinWrite(void);
extern void GPR_Is51MClockInUse(void);
extern void GPR_USBCHRST_ResetReq_SetVal(void);
extern void GPR_USBCPhy_ResetReq_SetVal(void);
extern void GPR_USBPAPB_ResetReq_SetVal(void);
extern void GPR_USBPPor_ResetReq_SetVal(void);
extern void GPR_USBPUtmi_ResetReq_SetVal(void);
extern void GPR_USB_DM_Ctrl_Disable_Rst(void);
extern void GPR_USB_DM_Ctrl_Enable_Without_Usbcprst(void);
extern void GPR_apAccessEnter(void);
extern void GPR_apAccessExit(void);
extern void GPR_apDFCVote4CP(void);
extern void GPR_apDFCVoteIdle(void);
extern void GPR_apSysClkForceOnControl(void);
extern void GPR_bootSetting(void);
extern void GPR_clockDisable(void);
extern void GPR_clockEnable(void);
extern void GPR_clockEnableCheck(void);
extern void GPR_cpGetRstSrc(void);
extern void GPR_cpResetCfgSet(void);
extern void GPR_csmbAccessEnter(void);
extern void GPR_csmbAccessExit(void);
extern void GPR_flashClockDisable(void);
extern void GPR_flashClockEnable(void);
extern void GPR_flashSWReset(void);
extern void GPR_getClockFreq(void);
extern void GPR_getSystickClk(void);
extern void GPR_initialize(void);
extern void GPR_lockUpActionCtrl(void);
extern void GPR_rmiHrstRel(void);
extern void GPR_setApbGprAcg(void);
extern void GPR_setClockDiv(void);
extern void GPR_setClockSrc(void);
extern void GPR_setFlashClockDiv(void);
extern void GPR_setFlashClockSrc(void);
extern void GPR_swReset(void);
extern void GPR_swResetModule(void);
extern void GPR_switchSystickClk(void);
extern void GPR_unilogSWReset(void);
extern void GPR_usbUlgClr(void);
extern void GPR_usbUlgSet(void);
extern void HAL_ADC_CalibrateRawCode(void);
extern void HAL_ADC_ConvertThermalRawCodeToTemperatureHighAccuracy(void);
extern void HAL_QSPI_Command(void);
extern void HAL_QSPI_Config(void);
extern void HAL_QSPI_Init(void);
extern void HAL_QSPI_Receive(void);
extern void HAL_QSPI_Set_CPflh_Clk(void);
extern void HAL_QSPI_Set_Clk(void);
extern void HAL_QSPI_Transmit(void);
extern void HAL_QSPI_XIP_Enable(void);
extern void HAL_UartDumpPortCheck(void);
extern void HAL_UartDumpPortInit(void);
extern void HAL_UartDumpPortSend(void);
extern void I2C0_IRQHandler(void);
extern void I2C1_IRQHandler(void);
extern void I2C_Control(void);
extern void I2C_GetCapabilities(void);
extern void I2C_GetClockFreq(void);
extern void I2C_GetDataCount(void);
extern void I2C_GetStatus(void);
extern void I2C_IRQHandler(void);
extern void I2C_Initialize(void);
extern void I2C_MasterReceive(void);
extern void I2C_MasterTransmit(void);
extern void I2C_PowerControl(void);
extern void I2C_SlaveReceive(void);
extern void I2C_Uninitialize(void);
extern void OsaSystemTimeReadRamUtc(void);
extern void OsaTimerSync(void);
extern void PAD_driverInit(void);
extern void PAD_enterLowPowerStatePrepare(void);
extern void PAD_exitLowPowerStateRestore(void);
extern void PAD_getDefaultConfig(void);
extern void PAD_setPinConfig(void);
extern void PAD_setPinPullConfig(void);
extern void Pad0_WakeupIntHandler(void);
extern void Pad1_WakeupIntHandler(void);
extern void Pad2_WakeupIntHandler(void);
extern void Pad3_WakeupIntHandler(void);
extern void Pad4_WakeupIntHandler(void);
extern void Pad5_WakeupIntHandler(void);
extern void QSPI_CheckQEnFlag(void);
extern void QSPI_PollingBusyFlagIntableOnce(void);
extern void RTC_WakeupIntHandler(void);
extern void ResetStateGet(void);
extern void SPI0_IrqHandler(void);
extern void SPI1_IrqHandler(void);
extern void SPI_BlockTransfer(void);
extern void SPI_FastTransfer(void);
extern void SPI_FlashBlockTransfer(void);
extern void SPI_GetSpeed(void);
extern void SPI_IsTransferBusy(void);
extern void SPI_MasterInit(void);
extern void SPI_SetCallbackFun(void);
extern void SPI_SetDMAEnable(void);
extern void SPI_SetDMATrigger(void);
extern void SPI_SetNewConfig(void);
extern void SPI_SetNoBlock(void);
extern void SPI_SetTxOnlyFlag(void);
extern void SPI_TransferEx(void);
extern void SPI_TransferStop(void);
extern void SPI_WaitTransferNoBusy(void);
extern void TIMER_clearInterruptFlags(void);
extern void TIMER_deInit(void);
extern void TIMER_driverInit(void);
extern void TIMER_getDefaultConfig(void);
extern void TIMER_getInterruptFlags(void);
extern void TIMER_init(void);
extern void TIMER_interruptConfig(void);
extern void TIMER_start(void);
extern void TIMER_stop(void);
extern void UART_flush(void);
extern void UART_init(void);
extern void UART_receive(void);
extern void UART_send(void);
extern void UART_setBaudrate(void);
extern void USART0_DmaRxEvent(void);
extern void USART0_DmaTxEvent(void);
extern void USART0_IRQHandler(void);
extern void USART1_DmaRxEvent(void);
extern void USART1_DmaTxEvent(void);
extern void USART1_IRQHandler(void);
extern void USART2_DmaRxEvent(void);
extern void USART2_DmaTxEvent(void);
extern void USART2_IRQHandler(void);
extern void USART_Control(void);
extern void USART_DmaRxEvent(void);
extern void USART_DmaTxEvent(void);
extern void USART_GetBaudRate(void);
extern void USART_GetCapabilities(void);
extern void USART_GetModemStatus(void);
extern void USART_GetRxCount(void);
extern void USART_GetStatus(void);
extern void USART_GetTxCount(void);
extern void USART_IRQHandler(void);
extern void USART_Initialize(void);
extern void USART_PowerControl(void);
extern void USART_Receive(void);
extern void USART_Send(void);
extern void USART_SendPolling(void);
extern void USART_SetBaudrate(void);
extern void USART_SetModemControl(void);
extern void USART_Uninitialize(void);
extern void WDT_deInit(void);
extern void WDT_getStartStatus(void);
extern void WDT_init(void);
extern void WDT_kick(void);
extern void WDT_start(void);
extern void WDT_stop(void);
extern void WDT_unlock(void);
extern void XIC_EnableIRQ(void);
extern void XIC_SetVector(void);
extern void _ZSt25__throw_bad_function_callv(void);
extern void _ZdaPv(void);
extern void _ZdlPv(void);
// NO C++ runtime symbols (std::*, libstdc++ helpers) in this list: with the
// two-stage link each slot carries its OWN compiler runtime in-slot, and a
// base export would silently re-couple slots to the base's libstdc++ and
// recreate the comdat-spill failure.
extern void __aeabi_atexit(void);
extern void __aeabi_cdcmpeq(void);
extern void __aeabi_cdcmple(void);
extern void __aeabi_cdrcmple(void);
extern void __aeabi_d2f(void);
extern void __aeabi_d2iz(void);
extern void __aeabi_d2lz(void);
extern void __aeabi_d2uiz(void);
extern void __aeabi_d2ulz(void);
extern void __aeabi_dadd(void);
extern void __aeabi_dcmpeq(void);
extern void __aeabi_dcmpge(void);
extern void __aeabi_dcmpgt(void);
extern void __aeabi_dcmple(void);
extern void __aeabi_dcmplt(void);
extern void __aeabi_dcmpun(void);
extern void __aeabi_ddiv(void);
extern void __aeabi_dmul(void);
extern void __aeabi_drsub(void);
extern void __aeabi_dsub(void);
extern void __aeabi_f2d(void);
extern void __aeabi_i2d(void);
extern void __aeabi_l2d(void);
extern void __aeabi_ldivmod(void);
extern void __aeabi_ui2d(void);
extern void __aeabi_ul2d(void);
extern void __aeabi_uldivmod(void);
extern void __assert_func(void);
extern void __cxa_thread_atexit(void);
extern void __emutls_get_address(void);
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
extern void fabs(void);
extern void fclose(void);
extern void feof(void);
extern void fflush(void);
extern void floor(void);
extern void fmod(void);
extern void fopen(void);
extern void fotaNvmNfsPeInit(void);
extern void fputc(void);
extern void fputs(void);
extern void fread(void);
extern void free(void);
extern void fseek(void);
extern void fwrite(void);
extern void gmtime_r(void);
extern void gpio_set_pad_wakeup_callback(void);
extern void isspace(void);
extern void localtime_r(void);
extern void log(void);
extern void luat_mobile_config(void);
extern void luat_rtos_task_create(void);
extern void luat_rtos_task_sleep(void);
extern void luat_uart_exist(void);
extern void luat_uart_write(void);
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
extern void pwrKeyIntHandler(void);
extern void rand(void);
extern void realloc(void);
extern void registerPSEventCallback(void);
extern void rngGenRandom(void);
extern void round(void);
extern void sin(void);
extern void sinh(void);
extern void anchor_console(void);
extern void anchor_read(void);
extern void anchor_set_console(void);
extern void anchor_table(void);
extern void anchor_write(void);
extern void anchor_write_table(void);
extern void slpManAONIOLatchEn(void);
// The RTC-backed libc time shims (--wrap=time & friends): only slot code
// references them (the base's own SDK paths do not call libc time), so
// without keep entries the base link garbage-collects the definitions the
// slot's --wrap flags rely on.
extern void __wrap_time(void);
extern void __wrap_clock(void);
extern void __wrap_localtime(void);
extern void __wrap_gmtime(void);
extern void slpManAONIOPowerOff(void);
extern void slpManAONIOPowerOn(void);
extern void slpManAONIOVoltGet(void);
extern void slpManAONIOVoltSet(void);
extern void slpManAonWdtFeed(void);
extern void slpManAonWdtStop(void);
extern void slpManApplyPlatVoteHandle(void);
extern void slpManDeepSlpTimerDel(void);
extern void slpManDeepSlpTimerRegisterExpCb(void);
extern void slpManDeepSlpTimerStart(void);
extern void slpManDrvVoteSleep(void);
extern void slpManExcutePredefinedBackupCb(void);
extern void slpManExcutePredefinedBackupCbInPaging(void);
extern void slpManExcutePredefinedRestoreCb(void);
extern void slpManExcutePredefinedRestoreCbInPaging(void);
extern void slpManExcuteUsrdefinedBackupCb(void);
extern void slpManExcuteUsrdefinedRestoreCb(void);
extern void slpManExtIntPreProcess(void);
extern void slpManGetDrvBitmap(void);
extern void slpManGetDrvVoteMask(void);
extern void slpManGetLastSlpState(void);
extern void slpManGetWakeupPadCfg(void);
extern void slpManGetWakeupPinValue(void);
extern void slpManGetWakeupSrc(void);
extern void slpManGivebackPlatVoteHandle(void);
extern void slpManPlatGetSlpState(void);
extern void slpManPlatVoteDisableSleep(void);
extern void slpManPlatVoteEnableSleep(void);
extern void slpManProductionTest(void);
extern void slpManRegisterPredefinedBackupCb(void);
extern void slpManRegisterPredefinedRestoreCb(void);
extern void slpManSetDrvVoteMask(void);
extern void slpManSetPmuSleepMode(void);
extern void slpManSetWakeupPadCfg(void);
extern void slpManStartPowerOff(void);
extern void slpManUnregisterPredefinedBackupCb(void);
extern void slpManUnregisterPredefinedRestoreCb(void);
extern void slpManUpdatePmuTimingCfg(void);
extern void snprintf(void);
extern void soc_call_function_in_service(void);
extern void soc_cms_proc(void);
extern void soc_disable_tcpip_use_default_pdp(void);
extern void soc_fast_printf(void);
extern void soc_free_later(void);
extern void soc_get_poweron_time_ms(void);
extern void soc_get_poweron_time_tick(void);
extern void soc_info(void);
extern void soc_mobile_default_pdn_ip_type(void);
extern void soc_mobile_search_cell_info_async(void);
extern void soc_mobile_set_rrc_release_time(void);
extern void soc_netif_input_prepare(void);
extern void soc_power_mode(void);
extern void soc_printf(void);
extern void soc_set_usb_sleep(void);
extern void soc_uart0_set_log_off(void);
extern void soc_unilog_callback(void);
extern void soc_usb_onoff(void);
extern void soc_usb_serial_output(void);
extern void soc_vsprintf(void);
extern void sprintf(void);
extern void sqrt(void);
extern void srand(void);
extern void sscanf(void);
extern void strcat(void);
extern void strchr(void);
extern void strcmp(void);
extern void strcpy(void);
extern void strcspn(void);
extern void strdup(void);
extern void strerror(void);
extern void strlen(void);
extern void strncat(void);
extern void strncmp(void);
extern void strncpy(void);
extern void strnlen(void);
extern void strspn(void);
extern void strstr(void);
extern void strtod(void);
extern void strtoul(void);
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
extern void vsnprintf(void);
extern void xQueueCreateMutex(void);
extern void xQueueGenericCreate(void);
extern void xQueueGenericReceive(void);
extern void xQueueGenericSend(void);
extern void xQueueGenericSendFromISR(void);
extern void xQueueGetMutexHolder(void);
extern void xTaskCreate(void);
extern void xTaskGenericNotify(void);
extern void xTaskGetCurrentTaskHandle(void);
extern void xTaskNotifyWait(void);

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
  (const void*)&ARM_I2C_GetVersion,
  (const void*)&ARM_USART_GetVersion,
  (const void*)&BSP_CommonInit,
  (const void*)&BSP_CustomInit,
  (const void*)&BSP_DeInit_SmallImg,
  (const void*)&BSP_FlashNVICSwReset,
  (const void*)&BSP_FlashSetGvarforSlp2,
  (const void*)&BSP_GetFSAssertCount,
  (const void*)&BSP_GetPlatConfigItemValue,
  (const void*)&BSP_GetRawFlashPlatConfig,
  (const void*)&BSP_Init_SmallImg,
  (const void*)&BSP_LoadPlatConfigFromFs,
  (const void*)&BSP_LoadPlatConfigFromRawFlash,
  (const void*)&BSP_QSPI_Erase_Cmd,
  (const void*)&BSP_QSPI_Erase_Proc,
  (const void*)&BSP_QSPI_Erase_Safe,
  (const void*)&BSP_QSPI_Erase_Sector,
  (const void*)&BSP_QSPI_Init,
  (const void*)&BSP_QSPI_Read_Safe,
  (const void*)&BSP_QSPI_Read_Status_Reg,
  (const void*)&BSP_QSPI_SWReset,
  (const void*)&BSP_QSPI_Write,
  (const void*)&BSP_QSPI_Write_Gran_Cmd,
  (const void*)&BSP_QSPI_Write_Proc,
  (const void*)&BSP_QSPI_Write_Safe,
  (const void*)&BSP_QSPI_Write_Volatile_Status_Reg,
  (const void*)&BSP_QSPI_XIP_Mode_Disable,
  (const void*)&BSP_QSPI_XIP_Mode_Enable,
  (const void*)&BSP_SavePlatConfigToFs,
  (const void*)&BSP_SavePlatConfigToRawFlash,
  (const void*)&BSP_SetFSAssertCount,
  (const void*)&BSP_SetFsPorDefaultValue,
  (const void*)&BSP_SetPlatConfigItemValue,
  (const void*)&BSP_UsbDeInit,
  (const void*)&BSP_UsbInit,
  (const void*)&CLOCK_AssertChkBeforeSlp,
  (const void*)&CLOCK_Trace,
  (const void*)&CLOCK_checkClkID,
  (const void*)&CLOCK_clockDisable,
  (const void*)&CLOCK_clockEnable,
  (const void*)&CLOCK_clockReset,
  (const void*)&CLOCK_getClockFreq,
  (const void*)&CLOCK_setClockDiv,
  (const void*)&CLOCK_setClockSrc,
  (const void*)&DMA_ForceStartStream,
  (const void*)&DMA_buildDescriptor,
  (const void*)&DMA_closeChannel,
  (const void*)&DMA_disableChannelInterrupts,
  (const void*)&DMA_enableChannelInterrupts,
  (const void*)&DMA_getChannelCount,
  (const void*)&DMA_getChannelCurrentTargetAddress,
  (const void*)&DMA_init,
  (const void*)&DMA_loadChannelDescriptorAndRun,
  (const void*)&DMA_loadChannelFirstDescriptor,
  (const void*)&DMA_openChannel,
  (const void*)&DMA_resetChannel,
  (const void*)&DMA_resumeChannel,
  (const void*)&DMA_rigisterChannelCallback,
  (const void*)&DMA_setChannelRequestSource,
  (const void*)&DMA_setDescriptorTransferLen,
  (const void*)&DMA_startChannel,
  (const void*)&DMA_stopChannel,
  (const void*)&DMA_stopChannelNoWait,
  (const void*)&DMA_suspendChannel,
  (const void*)&DMA_transferSetup,
  (const void*)&GPIO_Config,
  (const void*)&GPIO_EnterLowPowerStatePrepare,
  (const void*)&GPIO_ExitLowPowerStateRestore,
  (const void*)&GPIO_ExtiConfig,
  (const void*)&GPIO_ExtiSetCB,
  (const void*)&GPIO_FastOutput,
  (const void*)&GPIO_GlobalInit,
  (const void*)&GPIO_Input,
  (const void*)&GPIO_InputMulti,
  (const void*)&GPIO_IomuxEC618,
  (const void*)&GPIO_OutPulse,
  (const void*)&GPIO_Output,
  (const void*)&GPIO_OutputMulti,
  (const void*)&GPIO_PullConfig,
  (const void*)&GPIO_ToPadEC618,
  (const void*)&GPIO_Toggle,
  (const void*)&GPIO_ToggleMulti,
  (const void*)&GPIO_WakeupPadConfig,
  (const void*)&GPIO_clearInterruptFlags,
  (const void*)&GPIO_driverInit,
  (const void*)&GPIO_enterLowPowerStatePrepare,
  (const void*)&GPIO_exitLowPowerStateRestore,
  (const void*)&GPIO_getInterruptFlags,
  (const void*)&GPIO_interruptConfig,
  (const void*)&GPIO_pinConfig,
  (const void*)&GPIO_pinRead,
  (const void*)&GPIO_pinWrite,
  (const void*)&GPR_Is51MClockInUse,
  (const void*)&GPR_USBCHRST_ResetReq_SetVal,
  (const void*)&GPR_USBCPhy_ResetReq_SetVal,
  (const void*)&GPR_USBPAPB_ResetReq_SetVal,
  (const void*)&GPR_USBPPor_ResetReq_SetVal,
  (const void*)&GPR_USBPUtmi_ResetReq_SetVal,
  (const void*)&GPR_USB_DM_Ctrl_Disable_Rst,
  (const void*)&GPR_USB_DM_Ctrl_Enable_Without_Usbcprst,
  (const void*)&GPR_apAccessEnter,
  (const void*)&GPR_apAccessExit,
  (const void*)&GPR_apDFCVote4CP,
  (const void*)&GPR_apDFCVoteIdle,
  (const void*)&GPR_apSysClkForceOnControl,
  (const void*)&GPR_bootSetting,
  (const void*)&GPR_clockDisable,
  (const void*)&GPR_clockEnable,
  (const void*)&GPR_clockEnableCheck,
  (const void*)&GPR_cpGetRstSrc,
  (const void*)&GPR_cpResetCfgSet,
  (const void*)&GPR_csmbAccessEnter,
  (const void*)&GPR_csmbAccessExit,
  (const void*)&GPR_flashClockDisable,
  (const void*)&GPR_flashClockEnable,
  (const void*)&GPR_flashSWReset,
  (const void*)&GPR_getClockFreq,
  (const void*)&GPR_getSystickClk,
  (const void*)&GPR_initialize,
  (const void*)&GPR_lockUpActionCtrl,
  (const void*)&GPR_rmiHrstRel,
  (const void*)&GPR_setApbGprAcg,
  (const void*)&GPR_setClockDiv,
  (const void*)&GPR_setClockSrc,
  (const void*)&GPR_setFlashClockDiv,
  (const void*)&GPR_setFlashClockSrc,
  (const void*)&GPR_swReset,
  (const void*)&GPR_swResetModule,
  (const void*)&GPR_switchSystickClk,
  (const void*)&GPR_unilogSWReset,
  (const void*)&GPR_usbUlgClr,
  (const void*)&GPR_usbUlgSet,
  (const void*)&HAL_ADC_CalibrateRawCode,
  (const void*)&HAL_ADC_ConvertThermalRawCodeToTemperatureHighAccuracy,
  (const void*)&HAL_QSPI_Command,
  (const void*)&HAL_QSPI_Config,
  (const void*)&HAL_QSPI_Init,
  (const void*)&HAL_QSPI_Receive,
  (const void*)&HAL_QSPI_Set_CPflh_Clk,
  (const void*)&HAL_QSPI_Set_Clk,
  (const void*)&HAL_QSPI_Transmit,
  (const void*)&HAL_QSPI_XIP_Enable,
  (const void*)&HAL_UartDumpPortCheck,
  (const void*)&HAL_UartDumpPortInit,
  (const void*)&HAL_UartDumpPortSend,
  (const void*)&I2C0_IRQHandler,
  (const void*)&I2C1_IRQHandler,
  (const void*)&I2C_Control,
  (const void*)&I2C_GetCapabilities,
  (const void*)&I2C_GetClockFreq,
  (const void*)&I2C_GetDataCount,
  (const void*)&I2C_GetStatus,
  (const void*)&I2C_IRQHandler,
  (const void*)&I2C_Initialize,
  (const void*)&I2C_MasterReceive,
  (const void*)&I2C_MasterTransmit,
  (const void*)&I2C_PowerControl,
  (const void*)&I2C_SlaveReceive,
  (const void*)&I2C_Uninitialize,
  (const void*)&OsaSystemTimeReadRamUtc,
  (const void*)&OsaTimerSync,
  (const void*)&PAD_driverInit,
  (const void*)&PAD_enterLowPowerStatePrepare,
  (const void*)&PAD_exitLowPowerStateRestore,
  (const void*)&PAD_getDefaultConfig,
  (const void*)&PAD_setPinConfig,
  (const void*)&PAD_setPinPullConfig,
  (const void*)&Pad0_WakeupIntHandler,
  (const void*)&Pad1_WakeupIntHandler,
  (const void*)&Pad2_WakeupIntHandler,
  (const void*)&Pad3_WakeupIntHandler,
  (const void*)&Pad4_WakeupIntHandler,
  (const void*)&Pad5_WakeupIntHandler,
  (const void*)&QSPI_CheckQEnFlag,
  (const void*)&QSPI_PollingBusyFlagIntableOnce,
  (const void*)&RTC_WakeupIntHandler,
  (const void*)&ResetStateGet,
  (const void*)&SPI0_IrqHandler,
  (const void*)&SPI1_IrqHandler,
  (const void*)&SPI_BlockTransfer,
  (const void*)&SPI_FastTransfer,
  (const void*)&SPI_FlashBlockTransfer,
  (const void*)&SPI_GetSpeed,
  (const void*)&SPI_IsTransferBusy,
  (const void*)&SPI_MasterInit,
  (const void*)&SPI_SetCallbackFun,
  (const void*)&SPI_SetDMAEnable,
  (const void*)&SPI_SetDMATrigger,
  (const void*)&SPI_SetNewConfig,
  (const void*)&SPI_SetNoBlock,
  (const void*)&SPI_SetTxOnlyFlag,
  (const void*)&SPI_TransferEx,
  (const void*)&SPI_TransferStop,
  (const void*)&SPI_WaitTransferNoBusy,
  (const void*)&TIMER_clearInterruptFlags,
  (const void*)&TIMER_deInit,
  (const void*)&TIMER_driverInit,
  (const void*)&TIMER_getDefaultConfig,
  (const void*)&TIMER_getInterruptFlags,
  (const void*)&TIMER_init,
  (const void*)&TIMER_interruptConfig,
  (const void*)&TIMER_start,
  (const void*)&TIMER_stop,
  (const void*)&UART_flush,
  (const void*)&UART_init,
  (const void*)&UART_receive,
  (const void*)&UART_send,
  (const void*)&UART_setBaudrate,
  (const void*)&USART0_DmaRxEvent,
  (const void*)&USART0_DmaTxEvent,
  (const void*)&USART0_IRQHandler,
  (const void*)&USART1_DmaRxEvent,
  (const void*)&USART1_DmaTxEvent,
  (const void*)&USART1_IRQHandler,
  (const void*)&USART2_DmaRxEvent,
  (const void*)&USART2_DmaTxEvent,
  (const void*)&USART2_IRQHandler,
  (const void*)&USART_Control,
  (const void*)&USART_DmaRxEvent,
  (const void*)&USART_DmaTxEvent,
  (const void*)&USART_GetBaudRate,
  (const void*)&USART_GetCapabilities,
  (const void*)&USART_GetModemStatus,
  (const void*)&USART_GetRxCount,
  (const void*)&USART_GetStatus,
  (const void*)&USART_GetTxCount,
  (const void*)&USART_IRQHandler,
  (const void*)&USART_Initialize,
  (const void*)&USART_PowerControl,
  (const void*)&USART_Receive,
  (const void*)&USART_Send,
  (const void*)&USART_SendPolling,
  (const void*)&USART_SetBaudrate,
  (const void*)&USART_SetModemControl,
  (const void*)&USART_Uninitialize,
  (const void*)&WDT_deInit,
  (const void*)&WDT_getStartStatus,
  (const void*)&WDT_init,
  (const void*)&WDT_kick,
  (const void*)&WDT_start,
  (const void*)&WDT_stop,
  (const void*)&WDT_unlock,
  (const void*)&XIC_EnableIRQ,
  (const void*)&XIC_SetVector,
  (const void*)&_ZSt25__throw_bad_function_callv,
  (const void*)&_ZdaPv,
  (const void*)&_ZdlPv,
  (const void*)&__aeabi_atexit,
  (const void*)&__aeabi_cdcmpeq,
  (const void*)&__aeabi_cdcmple,
  (const void*)&__aeabi_cdrcmple,
  (const void*)&__aeabi_d2f,
  (const void*)&__aeabi_d2iz,
  (const void*)&__aeabi_d2lz,
  (const void*)&__aeabi_d2uiz,
  (const void*)&__aeabi_d2ulz,
  (const void*)&__aeabi_dadd,
  (const void*)&__aeabi_dcmpeq,
  (const void*)&__aeabi_dcmpge,
  (const void*)&__aeabi_dcmpgt,
  (const void*)&__aeabi_dcmple,
  (const void*)&__aeabi_dcmplt,
  (const void*)&__aeabi_dcmpun,
  (const void*)&__aeabi_ddiv,
  (const void*)&__aeabi_dmul,
  (const void*)&__aeabi_drsub,
  (const void*)&__aeabi_dsub,
  (const void*)&__aeabi_f2d,
  (const void*)&__aeabi_i2d,
  (const void*)&__aeabi_l2d,
  (const void*)&__aeabi_ldivmod,
  (const void*)&__aeabi_ui2d,
  (const void*)&__aeabi_ul2d,
  (const void*)&__aeabi_uldivmod,
  (const void*)&__assert_func,
  (const void*)&__cxa_thread_atexit,
  (const void*)&__emutls_get_address,
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
  (const void*)&fabs,
  (const void*)&fclose,
  (const void*)&feof,
  (const void*)&fflush,
  (const void*)&floor,
  (const void*)&fmod,
  (const void*)&fopen,
  (const void*)&fotaNvmNfsPeInit,
  (const void*)&fputc,
  (const void*)&fputs,
  (const void*)&fread,
  (const void*)&free,
  (const void*)&fseek,
  (const void*)&fwrite,
  (const void*)&gmtime_r,
  (const void*)&gpio_set_pad_wakeup_callback,
  (const void*)&isspace,
  (const void*)&localtime_r,
  (const void*)&log,
  (const void*)&luat_mobile_config,
  (const void*)&luat_rtos_task_create,
  (const void*)&luat_rtos_task_sleep,
  (const void*)&luat_uart_exist,
  (const void*)&luat_uart_write,
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
  (const void*)&pwrKeyIntHandler,
  (const void*)&rand,
  (const void*)&realloc,
  (const void*)&registerPSEventCallback,
  (const void*)&rngGenRandom,
  (const void*)&round,
  (const void*)&sin,
  (const void*)&sinh,
  (const void*)&anchor_console,
  (const void*)&anchor_read,
  (const void*)&anchor_set_console,
  (const void*)&anchor_table,
  (const void*)&anchor_write,
  (const void*)&anchor_write_table,
  (const void*)&slpManAONIOLatchEn,
  (const void*)&__wrap_time,
  (const void*)&__wrap_clock,
  (const void*)&__wrap_localtime,
  (const void*)&__wrap_gmtime,
  (const void*)&slpManAONIOPowerOff,
  (const void*)&slpManAONIOPowerOn,
  (const void*)&slpManAONIOVoltGet,
  (const void*)&slpManAONIOVoltSet,
  (const void*)&slpManAonWdtFeed,
  (const void*)&slpManAonWdtStop,
  (const void*)&slpManApplyPlatVoteHandle,
  (const void*)&slpManDeepSlpTimerDel,
  (const void*)&slpManDeepSlpTimerRegisterExpCb,
  (const void*)&slpManDeepSlpTimerStart,
  (const void*)&slpManDrvVoteSleep,
  (const void*)&slpManExcutePredefinedBackupCb,
  (const void*)&slpManExcutePredefinedBackupCbInPaging,
  (const void*)&slpManExcutePredefinedRestoreCb,
  (const void*)&slpManExcutePredefinedRestoreCbInPaging,
  (const void*)&slpManExcuteUsrdefinedBackupCb,
  (const void*)&slpManExcuteUsrdefinedRestoreCb,
  (const void*)&slpManExtIntPreProcess,
  (const void*)&slpManGetDrvBitmap,
  (const void*)&slpManGetDrvVoteMask,
  (const void*)&slpManGetLastSlpState,
  (const void*)&slpManGetWakeupPadCfg,
  (const void*)&slpManGetWakeupPinValue,
  (const void*)&slpManGetWakeupSrc,
  (const void*)&slpManGivebackPlatVoteHandle,
  (const void*)&slpManPlatGetSlpState,
  (const void*)&slpManPlatVoteDisableSleep,
  (const void*)&slpManPlatVoteEnableSleep,
  (const void*)&slpManProductionTest,
  (const void*)&slpManRegisterPredefinedBackupCb,
  (const void*)&slpManRegisterPredefinedRestoreCb,
  (const void*)&slpManSetDrvVoteMask,
  (const void*)&slpManSetPmuSleepMode,
  (const void*)&slpManSetWakeupPadCfg,
  (const void*)&slpManStartPowerOff,
  (const void*)&slpManUnregisterPredefinedBackupCb,
  (const void*)&slpManUnregisterPredefinedRestoreCb,
  (const void*)&slpManUpdatePmuTimingCfg,
  (const void*)&snprintf,
  (const void*)&soc_call_function_in_service,
  (const void*)&soc_cms_proc,
  (const void*)&soc_disable_tcpip_use_default_pdp,
  (const void*)&soc_fast_printf,
  (const void*)&soc_free_later,
  (const void*)&soc_get_poweron_time_ms,
  (const void*)&soc_get_poweron_time_tick,
  (const void*)&soc_info,
  (const void*)&soc_mobile_default_pdn_ip_type,
  (const void*)&soc_mobile_search_cell_info_async,
  (const void*)&soc_mobile_set_rrc_release_time,
  (const void*)&soc_netif_input_prepare,
  (const void*)&soc_power_mode,
  (const void*)&soc_printf,
  (const void*)&soc_set_usb_sleep,
  (const void*)&soc_uart0_set_log_off,
  (const void*)&soc_unilog_callback,
  (const void*)&soc_usb_onoff,
  (const void*)&soc_usb_serial_output,
  (const void*)&soc_vsprintf,
  (const void*)&sprintf,
  (const void*)&sqrt,
  (const void*)&srand,
  (const void*)&sscanf,
  (const void*)&strcat,
  (const void*)&strchr,
  (const void*)&strcmp,
  (const void*)&strcpy,
  (const void*)&strcspn,
  (const void*)&strdup,
  (const void*)&strerror,
  (const void*)&strlen,
  (const void*)&strncat,
  (const void*)&strncmp,
  (const void*)&strncpy,
  (const void*)&strnlen,
  (const void*)&strspn,
  (const void*)&strstr,
  (const void*)&strtod,
  (const void*)&strtoul,
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
  (const void*)&vsnprintf,
  (const void*)&xQueueCreateMutex,
  (const void*)&xQueueGenericCreate,
  (const void*)&xQueueGenericReceive,
  (const void*)&xQueueGenericSend,
  (const void*)&xQueueGenericSendFromISR,
  (const void*)&xQueueGetMutexHolder,
  (const void*)&xTaskCreate,
  (const void*)&xTaskGenericNotify,
  (const void*)&xTaskGetCurrentTaskHandle,
  (const void*)&xTaskNotifyWait,
};
