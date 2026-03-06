
# memory mapping for the soc 

Base Address	End Address			Size					Region / Peripheral					Status
0x0000_0000		0x0001_FFFF			128 KB				BRAM (Instruction + Data)		Existing 
0x4000_0000		0x4000_00FF			256 B					UART0 (AXI4-Lite)						Existing 
0x4001_0000		0x4001_00FF			256 B					PWM / Timer0 (AXI4-Lite)		Existing 
0x4002_0000		0x4002_00FF			256 B					I2C0 (AXI4-Lite)						Proposed
0x4003_0000		0x4003_00FF			256 B					SPI0 (AXI4-Lite)						Proposed
0x4004_0000		0x4004_00FF			256 B					CAN0 (AXI4-Lite)						Proposed
0x4005_0000		0x4005_00FF			256 B					ADC0 (AXI4-Lite)						Proposed
0x4006_0000		0x4006_00FF			256 B					DAC0 (AXI4-Lite)						Proposed
0x4007_0000		0x4007_00FF			256 B					GPIO0 (AXI4-Lite)						Proposed
0x9000_0000		0x9000_00FF			256 B					Testbench Control						Existing 
