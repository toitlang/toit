import gpio
import spi


main:
    bus/spi.Bus := platform == PLATFORM_FREERTOS?
        spi.Bus
            --miso=gpio.Pin 12
            --mosi=gpio.Pin 13
            --clock=gpio.Pin 14 
        :
        spi.VirtualBus 

    device := bus.device
        --cs=gpio.VirtualPin :: | value | print "Cs set to: $value"
        --dc=gpio.VirtualPin :: | value | print "Dc set to: $value"
        --address_bits=7
        --command_bits=7
        --frequency=2_000_000
        --mode=0
    

    result := device.transfer 
        #[0x00, 0x01, 0x02, 0x03]
        --address=0xFF
        --command=0xFF
        --dc=0
        --read
    
    print "Result of transfer: $result"

    catch:
        result = device.transfer 
            #[0x04, 0x05, 0x06, 0x07]
            --address=0xFF
            --command=0xFF
            --dc=1
            --read
            --keep_cs_active
        
        //Should not get here
        print "Implementation error as this was not called with \$spi.Device.with_reserved_bus"
        
    catch --trace:
        device.with_reserved_bus:
            result = device.transfer 
                #[0x04, 0x05, 0x06, 0x07]
                --address=0x01
                --command=0xAA
                --dc=1
                --read
                --keep_cs_active

            print "Result of transfer: $result"

            result = device.transfer
                #[0x08, 0x09, 0x0A, 0x0B]
                --address=0x01
                --command=0x55
                --dc=0

            print "Result of transfer: $result"