package require gpib
load gpib_tcl.dll

# just create a global array
set server(version) 1.0

# some globals
set forever 0
set ports {{2006 {}} {2007 {}} {443 {}}}

# If you want to use SSL on port 443 then you need to provide a pair of OpenSSL
# files for the keys. We setup the tls package here and below we can specify
# what command to use to create the socket for each port.
if {![catch {package require tls}] } {
   if {[file exists server-public.pem]} {
      ::tls::init \
      -certfile server-public.pem \
      -keyfile server-private.pem \
      -ssl2 1 \
      -ssl3 1 \
      -tls1 0 \
      -require 0 \
      -request 0
      # fix this if you change the ports variable above.
      lset ports 1 1 ::tls::socket
   }
}

# Which commands shall be understood by our protocol
set commands {
   evaluate
   execute
   gpibclear
   gpibclose
   gpibopen
   gpibread
   gpibsend
   help
   quit
   reload
   serialclose
   serialopen
   serialqueue
   serialflush
   serialread
   serialsend
   showstate
   shutdown
}

array unset help
array set help {
   {evaluate}         {execute a tcl command on the server}
   {execute <args>}   {execute an external command on the server}
   {gpibclear <args>} {causes the gpib board to perform a Selected Device Clear (SDC).}
   {gpibclose <args>} {close a gpib device.}
   {gpibopen <args>}  {open a gpib device.}
   {gpibread <args>}  {read from a gpib device.}
   {gpibsend <args>}  {send a gpib command to a device.}
   {serialclose <args>} {close a serial device.}
   {serialopen <args>} {open a serial device.}
   {serialqueue <args>} {query the queue on the serial port}
   {serialflush <args>} {flush the input command of the serial port}
   {serialread <args>} {read from a serial device.}
   {serialsend <args>} {send a serial command to a device.}
   {quit}             {close the remote connection}
   {help}             {display this help message.}
   {reload}           {reload the server}
   {shutdown}         {shutdown the server}
   {showstate}        {display connections status}
}

#-------------------------------------------------------------------------------
#
# return the upper number between 2 numbers
#
#-------------------------------------------------------------------------------
proc max {a b} {
   expr {$a > $b ? $a : $b}
} ;# end proc max

#-------------------------------------------------------------------------------
#
# format an array in a clean view
#
#-------------------------------------------------------------------------------
proc farray {array {separator =} {pattern *}} {
   upvar $array a
   set names [lsort [array names a $pattern]]
   set max 0
   foreach name $names {
      set max [max $max [string length $name]]
   }
   set result [list]
   foreach name $names {
      lappend result [format " %-*s %s %s" $max $name $separator $a($name)]
   }
   return [join $result "\n"]
} ;# end proc farray

proc showstate {{all ""}} {
   global state currentsocket
   
   switch -- [string tolower $all] {
      "all" {
         set nbuser [array size state]
         puts $currentsocket "$nbuser active connection"
         set id 1
         foreach skt [array name state] {
            array set s [fconfigure $skt]
            array set t $state($skt)
            foreach n [array name t] {
               set tmp($id.$n) $t($n)
            }
            set tmp($id.client) $s(-sockname)
            incr id
         }
         farray tmp -
      }
      default {
         array set s [fconfigure $currentsocket]
         array set tmp $state($currentsocket)
         set tmp(client) $s(-sockname)
         farray tmp -
      }
   }
}

#-------------------------------------------------------------------------------
#
# execute an external command on the server
#
#-------------------------------------------------------------------------------
proc evaluate {args} {
   if {[catch {set rt [eval $args]} err ]} {
      set rt "evaluate $err"
   }
   return $rt
} ;# end proc execute

#-------------------------------------------------------------------------------
#
# send the help message to the client
#
#-------------------------------------------------------------------------------
proc help {{{<command>} {}}} {
   global help
   set helps [farray help - ${<command>}*]
   if {$helps == ""} {
      set helps "No help available for ${<command>}!"
   }
   return "\n$helps\n"
} ;# end proc help

#-------------------------------------------------------------------------------
#
# close a remote connection
#
#-------------------------------------------------------------------------------
proc closeSocket {skt} {
   puts stderr "Closing $skt [clock format [clock seconds]]"
   catch {close $skt}
} ;# end proc closeSocket

#-------------------------------------------------------------------------------
#
# execute an external command on the server
#
#-------------------------------------------------------------------------------
proc execute {args} {
   if {[catch {set rt [eval exec $args]} err ]} {
      set rt "execute $err"
   }
   return $rt
} ;# end proc execute

#-------------------------------------------------------------------------------
#
# reload the server
#
#-------------------------------------------------------------------------------
proc quit {} {
   global state currentsocket
   after idle [list closeSocket $currentsocket]
   unset state($currentsocket)
   return "Good bye!"
} ;# end proc quit

#-------------------------------------------------------------------------------
#
# shutdown the server
#
#-------------------------------------------------------------------------------
proc shutdown {} {
   global forever serversockets
   
   if {[info exists serversockets]} {
      foreach sock $serversockets {
         catch {close $sock}
      }
      unset serversockets
   }

   set forever 1
} ;# end proc shutdown

#-------------------------------------------------------------------------------
#
# configure the server
#
#-------------------------------------------------------------------------------
proc Server {skt host port} {
   global state
   # set the buffer mode for the socket to "line"
   fconfigure $skt -blocking 0 -buffering line
   # setup a file event to listen for message
   fileevent $skt readable [list handleMessages $skt]

   set state($skt) [list socket $skt host $host port $port]

   # setup a file event to send a message
      set header "===========================\n"
   append header " Welcome to the Tcl server\n"
   append header " TITANCOM - Just Push Play\n"
   append header " http://www.titancom.eu\n"
   append header " contact@titancom.eu\n"
   append header "==========================="
   puts $skt $header
   puts -nonewline $skt "=>"
   flush $skt
} ;# end proc Server

#-------------------------------------------------------------------------------
#
# reload the server
#
#-------------------------------------------------------------------------------
proc reload {args} {
   after idle [list source [info script]]
   return "Matrix reloaded! ;)"
} ;# end proc reload

#-------------------------------------------------------------------------------
#
# procedure to connect a gpib device 
#      
#-------------------------------------------------------------------------------
proc gpibopen {args} {

   global server
   
   if {[llength $args] == 1} {
      set args [lindex $args 0]
   }
   array set opt [list -address 0 -sendeoi true -timeout 60] ;# -sendcr true|false -sendlf true|false -expect cr|lf|none
   if {[expr [llength $args] % 2] || [llength $args] == 0} {
      return "usage: gpibopen -address <add> -sendeoi <true|false> -timeout <s>"
   }
   array set opt $args

   set address $opt(-address)
   
   if {[info exists server($address)]} {
      return "already connected"
   } else {
      if {[catch {
         set dev [gpib open -address $address -sendeoi $opt(-sendeoi) -timeout $opt(-timeout) ]
         set server($address) $dev
         return "ok"
      } err ]} {
         return $err
      }
   }
} ;#end proc gpibOpen

#-------------------------------------------------------------------------------
#
# procedure to send command to a gpib device
#      
#-------------------------------------------------------------------------------
proc gpibsend {args} {

   global server

   if {[llength $args] == 1} {
      set args [lindex $args 0]
   }
   array set opt [list -address 0 -msg ""]
   if {[expr [llength $args] % 2]} {
      return "usage: gpibsend -address <add> -msg <cmd>"
   }
   array set opt $args
   set address $opt(-address)
   if {[info exists server($address)]} {
      if {[string length $opt(-msg)] > 2048} {
	  	 puts "statusbyte before: [GPIB_readStatusVariables]"
         puts [GPIB_send 0 $address $opt(-msg) 1]
		 after 10000
		 puts [GPIB_send 0 $address "*esr?" 1]
		 puts "statusbyte before: [GPIB_readStatusVariables]"
		 return "ok"
      } else {
         if {[catch {gpib write -device $server($address) -message $opt(-msg)} err]} {
            return $err
         } else {
            return "ok"
         }
      }
   } else {
      return "not connected"
   }

} ;#end proc gpibSend

#-------------------------------------------------------------------------------
#
# procedure to read from a gpib device
#
#-------------------------------------------------------------------------------
proc gpibread {args} {

   global server

   if {[llength $args] == 1} {
      set args [lindex $args 0]
   }
   array set opt [list -address 0]
   if {[expr [llength $args] % 2]} {
      return "usage: gpibread -address <add>"
   }
   array set opt $args
   set address $opt(-address)

   set rt ""
   if {[info exists server($address)]} {
      if {[catch {set rt [gpib read -device $server($address)] } err]} {
         return "error: $err"
      } else {
         return $rt
      }
   } else {
      return "error: not connected"
   }

} ;#end proc gpibread

#-------------------------------------------------------------------------------
#
# procedure to close a connection from a gpib device
#      
#-------------------------------------------------------------------------------
proc gpibclose {args} {

   global server

   if {[llength $args] == 1} {
      set args [lindex $args 0]
   }
   array set opt [list -address 0]
   if {[expr [llength $args] % 2]} {
      return "usage: gpibclose -address <add>"
   }
   array set opt $args
   set address $opt(-address)

   if {[info exists server($address)]} {
      gpib close -device $server($address)
      unset server($address)
      return "ok"
   } else {
      return "not connected"
   }
} ;#end proc gpibClose

#-------------------------------------------------------------------------------
#
# procedure to clear the gpib connection
#
#-------------------------------------------------------------------------------
proc gpibclear {args} {

   global server

   if {[llength $args] == 1} {
      set args [lindex $args 0]
   }
   array set opt [list -address 0]
   if {[expr [llength $args] % 2]} {
      return "usage: gpibclear -address <add>"
   }
   array set opt $args
   set address $opt(-address)

   if {[info exists server($address)]} {
      gpib clear -device $server($address)
      return "ok"
   } else {
      return "not connected"
   }
} ;#end proc gpibclear

#-------------------------------------------------------------------------------
#
# procedure to open a serial port
#
#-------------------------------------------------------------------------------
proc serialopen {args} {

   global server

   if {[llength $args] == 1} {
      set args [lindex $args 0]
   }
   array set opt [list -port com1 -mode 9600,n,8,1 -handshake none -sysbuffer 4096 -timeout 3]
   if {[expr [llength $args] % 2] || [llength $args] == 0} {
      return "usage: serialopen -port <com> -mode <baud,parity,bits,stop> -handshake <none|rtscts|xonxoff> -sysbuffer <size> -timeout <s>"
   }
   array set opt $args

   set port $opt(-port)

   if {[info exists server($port)]} {
      return "already connected"
   } else {
      if {[catch {
         set dev [open \\\\.\\$port w+ ]
         fconfigure $dev -blocking 0 -buffering none -translation crlf -timeout $opt(-timeout)
         fconfigure $dev -mode $opt(-mode) -handshake $opt(-handshake) -sysbuffer [list $opt(-sysbuffer) $opt(-sysbuffer)] -buffersize $opt(-sysbuffer) 
         after 500
         set server($port) $dev        
         return "ok"
      } err]} {
         return $err
      }
   }
} ;# end proc serialopen

#-------------------------------------------------------------------------------
#
# procedure to close a serial port
#
#-------------------------------------------------------------------------------
proc serialclose {args} {

   global server

   if {[llength $args] == 1} {
      set args [lindex $args 0]
   }
   array set opt [list -port com1]
   if {[expr [llength $args] % 2]} {
      return "usage: serialclose -port <com>"
   }
   array set opt $args
   set port $opt(-port)

   if {[info exists server($port)]} {
      close $server($port)
      unset server($port)
      return "ok"
   } else {
      return "not connected"
   }

} ;# end proc serialclose

#-------------------------------------------------------------------------------
#
# procedure to send a command to a serial port
#
#-------------------------------------------------------------------------------
proc serialsend {args} {

   global server

   if {[llength $args] == 1} {
      set args [lindex $args 0]
   }
   array set opt [list -port com1 -msg "" -end cr]
   if {[expr [llength $args] % 2]} {
      return "usage: serialsend -port <com> -msg <cmd> -end <none|cr|lf|crlf>"
   }
   array set opt $args
   set port $opt(-port)

   set msg [string trim $opt(-msg)]
   switch $opt(-end) {
      cr   {append msg "\r" }
      lf   {append msg "\n" }
      crlf {append msg "\r\n" }
      none - default {
         # do nothing
      }
   }
   if {[info exists server($port)]} {
      flush $server($port)
      after 150
      if {[catch {
         puts -nonewline $server($port) "$msg"
         flush $server($port)
      } err]} {
         return $err
      } else {
         return "ok"
      }
   } else {
      return "not connected"
   }
} ;# end proc serialsend

#-------------------------------------------------------------------------------
#
# procedure to flush a serial port
#
#-------------------------------------------------------------------------------
proc serialflush {args} {

   global server

   if {[llength $args] == 1} {
      set args [lindex $args 0]
   }
   array set opt [list -port com1]
   if {[expr [llength $args] % 2]} {
      return "usage: serialflush -port <com>"
   }
   array set opt $args
   set port $opt(-port)

   if {[info exists server($port)]} {
      flush $server($port)
      return "ok"
   } else {
      return "not connected"
   }

} ;# end proc serialflush

#-------------------------------------------------------------------------------
#
# procedure to query the queur on a serial port
#
#-------------------------------------------------------------------------------
proc serialqueue {args} {

   global server

   if {[llength $args] == 1} {
      set args [lindex $args 0]
   }
   array set opt [list -port com1]
   if {[expr [llength $args] % 2]} {
      return "usage: serialqueue -port <com>"
   }
   array set opt $args
   set port $opt(-port)

   if {[info exists server($port)]} {
      set rt [lindex [fconfigure $server($port) -queue ] 0 ]
      return $rt
   } else {
      return "not connected"
   }

} ;# end proc serialqueue

#-------------------------------------------------------------------------------
#
# procedure to read data from a serial port
#
#-------------------------------------------------------------------------------
proc serialread {args} {

   global server

   if {[llength $args] == 1} {
      set args [lindex $args 0]
   }
   array set opt [list -port com1]
   if {[expr [llength $args] % 2]} {
      return "usage: serialread -port <com>"
   }
   array set opt $args
   set port $opt(-port)

   set rt ""
   if {[info exists server($port)]} {
      if {[catch {set rt [read $server($port)] } err]} {
         return "error: $err"
      } else {
         return $rt
      }    
   } else {
      return "error: not connected"
   }
} ;# end proc serialsend

#-------------------------------------------------------------------------------
#
# procedure which processes device messages
#      
#-------------------------------------------------------------------------------
proc handleMessages {skt} {

   global server forever currentsocket

    # Do we have a disconnect?
    if {[eof $skt]} {
    puts stderr "DISCONNECT"
        closeSocket $skt
        return
    }

    # Does reading the socket give us an error?
    if {[catch {gets $skt line} ret] == -1} {
        puts stderr "Closing $skt on reading $ret"
        closeSocket $skt
        return
    }
    # Did we really get a whole line?
    if {$ret == -1} return

    # ... and is it not empty? ...
    set line [string trim $line]
    if {$line == ""} return
    set currentsocket $skt

   # OK, so log it ...
   puts stderr "$skt > $line"

   # ... evaluate it, ...
   if {[catch {slave eval $line} ret]} {
      set ret "ERROR: $ret"
   }
   # ... log the result ...
   puts stderr [regsub -all -line ^ $ret "$skt < "]

   # ... and send it back to the client.
   if {[catch {
      puts $skt "$ret=>"
#       puts -nonewline $skt "=>"
      flush $skt
   } err ]} {
      puts stderr "Closing $skt on writing $err"
      closeSocket $skt
   }

} ;# end proc handleMessages

#-------------------------------------------------------------------------------
# create a server in tcl
# this server should run on a desktop.
# the remote script will execute remote command thru this server
#-------------------------------------------------------------------------------
proc serverRemoteCommand {ports commands} {

   global serversockets
   
   # (re-)create a safe slave interpreter
   catch {interp delete slave}
   interp create -safe slave
   
   # remove all predefined commands from the slave
   foreach command [slave eval info commands] {
      slave hide $command
   }
   
   # link the commands for the protocol into the slave
   puts -nonewline stderr "Initializing commands:"
   foreach command $commands {
      puts -nonewline stderr " $command"
      interp alias slave $command {} $command
   }
   puts stderr ""
   
   #(re-)create the server socket
   if {[info exists serversockets]} {
      foreach sock $serversockets {
         catch {close $sock}
      }
      unset serversockets
   }
   
   puts -nonewline stderr "Opening sockets:"
   foreach {port} $ports {
      foreach {port socketCmd} $port {}
      if {$socketCmd == {}} { set socketCmd ::socket }
      puts -nonewline stderr " $port ($socketCmd)"
      lappend serversockets [$socketCmd -server Server $port]
   }
   puts stderr ""

} ;# end proc serverRemoteCommand

#-------------------------------------------------------------------------------
#
# MAIN
#
#-------------------------------------------------------------------------------
serverRemoteCommand $ports $commands
vwait forever
