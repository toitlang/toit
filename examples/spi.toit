import gpio
import spi

main:

    dc /gpio.Pin? := ?
    cs /gpio.Pin? := ?
    bus/spi.Bus   := ?

    if platform == PLATFORM_FREERTOS:
        bus = spi.Bus
                --miso=gpio.Pin 12
                --mosi=gpio.Pin 13
                --clock=gpio.Pin 14 
        
        cs = gpio.Pin 15
        dc = gpio.Pin 16

    else:
        bus = spi.VirtualBus 
        
        cs = gpio.VirtualPin :: | value | print "Cs set to: $value"
        dc = gpio.VirtualPin :: | value | print "Dc set to: $value"

    device := bus.device
        --cs=cs
        --dc=dc
        --address_bits=7
        --command_bits=7
        --frequency=2_000_000
        --mode=0
    
    to_transmit := #[0x00, 0x01, 0x02, 0x03]
    device.transfer 
        to_transmit
        --address=0xFF
        --command=0xFF
        --dc=0
        --read
    
    print "Result of transfer: $to_transmit"

    catch:
        to_transmit = #[0x04, 0x05, 0x06, 0x07]
        device.transfer 
            to_transmit
            --address=0xFF
            --command=0xFF
            --dc=1
            --read
            --keep_cs_active
        
        //Should not get here
        print "Implementation error as this was not called with \$spi.Device.with_reserved_bus"
        
    catch --trace:
        device.with_reserved_bus:
            to_transmit = #[0x04, 0x05, 0x06, 0x07]
            device.transfer 
                to_transmit
                --address=0x01
                --command=0xAA
                --dc=1
                --read
                --keep_cs_active

            print "Result of transfer: $to_transmit"

            to_transmit = #[0x08, 0x09, 0x0A, 0x0B]
            device.transfer
                to_transmit
                --address=0x01
                --command=0x55
                --dc=0

            print "Result of transfer: $to_transmit"

    