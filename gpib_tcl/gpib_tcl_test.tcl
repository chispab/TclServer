load gpib_tcl.dll
puts Hello
GPIB_sendIFC 0
foreach el [GPIB_findLstn] {
	#for {set i 0} {$i<10} {incr i} { puts "$el statusbyte [GPIB_readStatusVariables]"; after 10}
	
# 	GPIB_sendBinary 0 $el jos.txt 1
	
	GPIB_send 0 $el "*IDN?" 1
	
	for {set i 0} {$i<20} {incr i} { puts "$el statusbyte [GPIB_readStatusVariables]"; after 10 }
	puts "$el [GPIB_receive 0 $el 101 256]"
	#for {set i 0} {$i<10} {incr i} { puts "$el statusbyte [GPIB_readStatusVariables]"; after 10 }
	#GPIB_devClear 0 $el

}
puts Yello




