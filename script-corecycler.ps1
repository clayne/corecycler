<#
.AUTHOR
    sp00n
.VERSION
    0.7.0
.DESCRIPTION
    Sets the affinity of the Prime95 process to only one core and cycles through all the cores
    to test the stability of a Curve Optimizer setting
.LINK
    https://github.com/sp00n/corecycler
.NOTE
    Please excuse my amateurish code in this file, it's my first attempt at writing in PowerShell ._.
#>

# Global variables
$curDateTime          = Get-Date -format yyyy-MM-dd_HH-mm-ss
$settings             = $null
$logFilePath          = $null
$processWindowHandler = $null
$processId            = $null
$process              = $null
$processCounterPath   = $null
$coresWithError       = $null


# Add code definitions so that we can close the Prime95 window even if it's minimized to the tray
# The regular PowerShell way unfortunetely doesn't work in this case
$GetWindowDefinition = @'
    using System;
    using System.Text;
    using System.Collections.Generic;
    using System.Runtime.InteropServices;
    
    namespace Api {
        public class WinStruct {
            public string WinTitle {get; set; }
            public int MainWindowHandle { get; set; }
            public int ProcessId { get; set; }
        }
         
        public class ApiDef {
            private delegate bool CallBackPtr(int hwnd, int lParam);
            private static CallBackPtr callBackPtr = Callback;
            private static List<WinStruct> _WinStructList = new List<WinStruct>();

            [DllImport("User32.dll")]
            [return: MarshalAs(UnmanagedType.Bool)]
            private static extern bool EnumWindows(CallBackPtr lpEnumFunc, IntPtr lParam);

            [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
            static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
            
            [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
            static extern int GetWindowThreadProcessId(IntPtr hWnd, out int ProcessId);
            
            private static bool Callback(int hWnd, int lparam) {
                StringBuilder sb = new StringBuilder(256);
                int res = GetWindowText((IntPtr)hWnd, sb, 256);
                int pId;
                int tId = GetWindowThreadProcessId((IntPtr)hWnd, out pId);
                _WinStructList.Add(new WinStruct { MainWindowHandle = hWnd, WinTitle = sb.ToString(), ProcessId = pId });
                return true;
            }  

            public static List<WinStruct> GetWindows() {
                _WinStructList = new List<WinStruct>();
                EnumWindows(callBackPtr, IntPtr.Zero);
                return _WinStructList;
            }
        }
    }
'@

Add-Type -TypeDefinition $GetWindowDefinition -Language CSharpVersion3


$CloseWindowDefinition = @'
    using System;
    using System.Runtime.InteropServices;
    
    public static class Win32 {
        public static uint WM_CLOSE = 0x10;

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = false)]
        public static extern IntPtr SendMessage(IntPtr hWnd, UInt32 Msg, IntPtr wParam, IntPtr lParam);
    }
'@

Add-Type -TypeDefinition $CloseWindowDefinition



<##
 # Write a message to the screen and to the log file
 # .PARAM string $text The text to output
 # .RETURN void
 #>
function Write-Text {
    param(
        $text
    )
    
    Write-Host $text
    Add-Content $logFilePath ($text)
}


<##
 # Write a message to the screen with a specific color and to the log file
 # .PARAM string $text The text to output
 # .PARAM string $color The color
 # .RETURN void
 #>
function Write-ColorText {
    param(
        $text,
        $foregroundColor
    )

    # -ForegroundColor <ConsoleColor>
    # -BackgroundColor <ConsoleColor>
    # Black, DarkBlue, DarkGreen, DarkCyan, DarkRed, DarkMagenta, DarkYellow, Gray, DarkGray, Blue, Green, Cyan, Red, Magenta, Yellow, White
    
    Write-Host $text -ForegroundColor $foregroundColor
    Add-Content $logFilePath ($text)
}


<##
 # Throw a fatal error
 # .PARAM string $text The text to display
 # .RETURN void
 #>
function Exit-WithFatalError {
    param(
        $text
    )

    Write-ColorText('FATAL ERROR: ' + $text) Red
    Read-Host -Prompt 'Press Enter to exit'
    exit
}


<##
 # Get the settings
 # .PARAM void
 # .RETURN void
 #>
function Get-Settings {
    # Default config settings
    # Change the various settings in the config.ini file

    $defaultSettings = @{

        # The mode of the stress test
        # 'SSE':    lightest load on the processor, lowest temperatures, highest boost clock
        # 'AVX':    medium load on the processor, medium temperatures, medium boost clock
        # 'AVX2':   heaviest on the processor, highest temperatures, lowest boost clock
        # 'CUSTOM': you can define your own settings (see further below for setting the values)
        mode = 'SSE'


        # The FFT size preset to test
        # These are basically the presets as present in Prime95
        # Note: If "mode" is set to "CUSTOM", this setting will be ignored
        # 'Smallest':  Smallest FFT: 4K to 21K     - tests L1/L2 caches, high power/heat/CPU stress
        # 'Small':     Small FFT:    36K to 248K   - tests L1/L2/L3 caches, maximum power/heat/CPU stress
        # 'Large':     Large FFT:    426K to 8192K - stresses memory controller and RAM (although memory testing is disabled here by default!)
        # 'All':       All FFT:      4K to 8192K   - all of the above
        FFTSize = 'Small'


        # Set the runtime per core
        # You can use a value in seconds or use 'h' for hours, 'm' for minutes and 's' for seconds
        # Examples: 360 = 360 seconds
        #           1h4m = 1 hour, 4 minutes
        #           1.5m = 1.5 minutes = 90 seconds
        # Default: 360
        runtimePerCore = 360


        # The number of threads to use for testing
        # You can only choose between 1 and 2
        # If Hyperthreading / SMT is disabled, this will automatically be set to 1
        # Currently there's no automatic way to determine which core has thrown an error
        # Setting this to 1 causes higher boost clock speed (due to less heat)
        # Default is 1
        # Maximum is 2
        numberOfThreads = 1


        # The max number of iterations, 10000 is basically unlimited
        maxIterations = 10000


        # Ignore certain cores
        # These cores will not be tested
        # The enumeration starts with a 0
        # Example: $settings.coresToIgnore = @(0, 1, 2)
        coresToIgnore = @()


        # Restart the Prime95 process for each new core test
        # So each core will have the same sequence of FFT sizes
        # The sequence of FFT sizes for Small FFTs:
        # 40, 48, 56, 64, 72, 80, 84, 96, 112, 128, 144, 160, 192, 224, 240
        # Runtime on a 5900x: 5,x minutes
        # Note: The screen never seems to turn off with this setting enabled
        restartPrimeForEachCore = 0


        # The name of the log file
        # The $settings.mode and the $settings.FFTSize above will be added to the name (and a .log file ending)
        logfile = 'CoreCycler'


        # Set the custom settings here for the 'CUSTOM' mode
        # Note: The automatic detection at which FFT size an error likely occurred
        #       will not work if you change the FFT sizes
        customCpuSupportsAVX  = 0         # Needs to be set to 1 for AVX mode (and AVX2)
        customCpuSupportsAVX2 = 0         # Needs to be set to 1 for AVX2 mode
        customCpuSupportsFMA3 = 0         # Also needs to be set to 1 for AVX2 mode on Ryzen
        customMinTortureFFT   = 36        # The minimum FFT size to test
        customMaxTortureFFT   = 248       # The maximum FFT size to test
        customTortureMem      = 0         # The amount of memory to use in MB. 0 = In-Place
        customTortureTime     = 1         # The max amount of minutes for each FFT size
    }


    # Set the default settings
    $settings = $defaultSettings


    # The full path and name of the log file
    $Script:logfilePath = $PSScriptRoot + '\logs\' + $settings.logfile + '_' + $curDateTime + '_' + $settings.mode + '.log'


    # If no config file exists, copy the config.default.ini to config.ini
    if (!(Test-Path 'config.ini' -PathType leaf)) {
        
        if (!(Test-Path 'config.default.ini' -PathType leaf)) {
            Exit-WithFatalError('Neither config.ini nor config.default.ini found!')
        }

        Copy-Item -Path 'config.default.ini' -Destination 'config.ini'
    }


    # Read the config file and overwrite the default settings
    $userSettings = Get-Content -raw 'config.ini' | ConvertFrom-StringData

    foreach ($entry in $userSettings.GetEnumerator()) {
        # Special handling for coresToIgnore
        if ($entry.Name -eq 'coresToIgnore') {
            if ($entry.Value -and ![string]::IsNullOrEmpty($entry.Value) -and ![String]::IsNullOrWhiteSpace($entry.Value)) {
                # Split the string by comma and add to the coresToIgnore entry
                $entry.Value -split ',\s*' | ForEach-Object {
                    $settings.coresToIgnore += [Int]$_
                }
            }
        }

        # Setting cannot be empty
        elseif ($entry.Value -and ![string]::IsNullOrEmpty($entry.Value) -and ![String]::IsNullOrWhiteSpace($entry.Value)) {
            # For anything but the mode, logfile, and FFTSize parameters, transform the value to an integer
            if ($entry.Name -eq 'logfile' -or $entry.Name -eq 'mode' -or $entry.Name -eq 'FFTSize') {
                $settings[$entry.Name] = [String]$entry.Value
            }

            # Parse the runtime per core (seconds, minutes, hours)
            elseif ($entry.Name -eq 'runtimePerCore') {
                # Parse the hours, minutes, seconds
                if ($entry.Value.indexOf('h') -ge 0 -or $entry.Value.indexOf('m') -ge 0 -or $entry.Value.indexOf('s') -ge 0) {
                    $hasMatched = $entry.Value -match '((?<hours>\d+(\.\d+)*)h)*\s*((?<minutes>\d+(\.\d+)*)m)*\s*((?<seconds>\d+(\.\d+)*)s)*'
                    $seconds = [Double]$matches.hours * 60 * 60 + [Double]$matches.minutes * 60 + [Double]$matches.seconds
                    $settings[$entry.Name] = [Int]$seconds
                }

                # Treat the value as seconds
                else {
                    $settings[$entry.Name] = [Int]$entry.Value
                }
            }

            else {
                $settings[$entry.Name] = [Int]$entry.Value
            }
        }

        # If it is empty, just ignore and use the default setting
    }


    # Limit the number of threads to 1 - 2
    $settings.numberOfThreads = [Math]::Max(1, [Math]::Min(2, $settings.numberOfThreads))
    $settings.numberOfThreads = $(if ($isHyperthreadingEnabled) { $settings.numberOfThreads } else { 1 })


    # Store in the global variable
    $Script:settings = $settings
}


<##
 # Get the formatted runtime per core string
 # .PARAM int $seconds The runtime in seconds
 # .RETURN string The formatted runtime string
 #>
function Get-FormattedRuntimePerCoreString {
    param (
        $seconds
    )

    $runtimePerCoreStringArray = @()
    $timeSpan = [TimeSpan]::FromSeconds($seconds)

    if ( $timeSpan.Hours -ge 1 ) {
        $thisString = [String]$timeSpan.Hours + ' hour'

        if ( $timeSpan.Hours -gt 1 ) {
            $thisString += 's'
        }

        $runtimePerCoreStringArray += $thisString
    }

    if ( $timeSpan.Minutes -ge 1 ) {
        $thisString = [String]$timeSpan.Minutes + ' minute'

        if ( $timeSpan.Minutes -gt 1 ) {
            $thisString += 's'
        }

        $runtimePerCoreStringArray += $thisString
    }


    if ( $timeSpan.Seconds -ge 1 ) {
        $thisString = [String]$timeSpan.Seconds + ' second'

        if ( $timeSpan.Seconds -gt 1 ) {
            $thisString += 's'
        }

        $runtimePerCoreStringArray += $thisString
    }

    return ($runtimePerCoreStringArray -join ', ')
}


<##
 # Get the correct TortureWeak setting for the selected CPU settings
 # .PARAM void
 # .RETURN Int
 #>
function Get-TortureWeakValue {
    <#
    Calculation of the TortureWeak ini setting
    ------------------------------------------
    From Prime95\source\gwnum\cpuid.h:
    #define CPU_SSE            0x0100     /*     256   SSE instructions supported */
    #define CPU_SSE2           0x0200     /*     512   SSE2 instructions supported */
    #define CPU_SSE3           0x0400     /*    1024   SSE3 instructions supported */
    #define CPU_SSSE3          0x0800     /*    2048   Supplemental SSE3 instructions supported */
    #define CPU_SSE41          0x1000     /*    4096   SSE4.1 instructions supported */
    #define CPU_SSE42          0x2000     /*    8192   SSE4.2 instructions supported */
    #define CPU_AVX            0x4000     /*   16384   AVX instructions supported */
    #define CPU_FMA3           0x8000     /*   32768   Intel fused multiply-add instructions supported */
    #define CPU_FMA4           0x10000    /*   65536   AMD fused multiply-add instructions supported */
    #define CPU_AVX2           0x20000    /*  131072   AVX2 instructions supported */
    #define CPU_PREFETCHW      0x40000    /*  262144   PREFETCHW (the Intel version) instruction supported */
    #define CPU_PREFETCHWT1    0x80000    /*  524288   PREFETCHWT1 instruction supported */
    #define CPU_AVX512F        0x100000   /* 1048576   AVX512F instructions supported */
    #define CPU_AVX512PF       0x200000   /* 2097152   AVX512PF instructions supported */

    From Prime95\source\prime95\Prime95Doc.cpp:
    m_weak = dlg.m_avx512 * CPU_AVX512F + dlg.m_fma3 * CPU_FMA3 + dlg.m_avx * CPU_AVX + dlg.m_sse2 * CPU_SSE2;
    
    - Only CPU_AVX512F, CPU_FMA3, CPU_AVX & CPU_SSE2 is used for the calculation
    - If one of these is set to disabled, add the number to the total value
    - AVX512 is never available on Ryzen

    All enabled (except AVX512):
    1048576 --> CPU_AVX512F
    
    AVX2 disabled:
    1081344
    -1048576  --> CPU_AVX512F
    -32768    --> CPU_FMA3

    AVX disabled:
    1097728
    -1048576  --> CPU_AVX512F
    -32768    --> CPU_FMA3
    -16384    --> CPU_AVX
    #>

    # Convert '0' to true to 1 and 1 to false to 0
    $FMA3 = [Int]![Int]$prime95CPUSettings[$settings.mode].CpuSupportsFMA3
    $AVX  = [Int]![Int]$prime95CPUSettings[$settings.mode].CpuSupportsAVX

    # Add the various flag values if a feature is disabled
    $tortureWeakValue = 1048576 + ($FMA3 * 32768) + ($AVX * 16384)

    return $tortureWeakValue
}


<##
 # Get the main window handler for the Prime95 process
 # Even if minimized to the tray
 # .PARAM void
 # .RETURN void
 #>
function Get-Prime95WindowHandler {
    # 'Prime95 - Self-Test': worker running
    # 'Prime95': worker not running
    $windowObj = [Api.Apidef]::GetWindows() | Where-Object { $_.WinTitle -eq 'Prime95 - Self-Test' -or $_.WinTitle -eq 'Prime95' }
    
    # Override the global script variables
    $Script:processWindowHandler = $windowObj.MainWindowHandle
    $Script:processId = $windowObj.ProcessId
}


<##
 # Create the Prime95 config files (local.txt & prime.txt)
 # This depends on the $settings.mode variable
 # .PARAM string $configType The config type to set in the config files (SSE, AVX, AVX, CUSTOM)
 # .RETURN void
 #>
function Initialize-Prime95 {
    param (
        $configType
    )

    $configFile1 = $processPath + 'local.txt'
    $configFile2 = $processPath + 'prime.txt'

    if ($configType -ne 'CUSTOM' -and $configType -ne 'SSE' -and $configType -ne 'AVX' -and $configType -ne 'AVX2') {
        Exit-WithFatalError('Invalid mode type provided!')
    }

    # Create the local.txt and overwrite if necessary
    $null = New-Item $configFile1 -ItemType File -Force

    Set-Content $configFile1 'RollingAverageIsFromV27=1'
    
    # Limit the load to the selected number of threads
    Add-Content $configFile1 ('NumCPUs=1')
    Add-Content $configFile1 ('CoresPerTest=1')
    Add-Content $configFile1 ('CpuNumHyperthreads=' + $settings.numberOfThreads)
    Add-Content $configFile1 ('WorkerThreads='      + $settings.numberOfThreads)
    Add-Content $configFile1 ('CpuSupportsSSE='     + $prime95CPUSettings[$settings.mode].CpuSupportsSSE)
    Add-Content $configFile1 ('CpuSupportsSSE2='    + $prime95CPUSettings[$settings.mode].CpuSupportsSSE2)
    Add-Content $configFile1 ('CpuSupportsAVX='     + $prime95CPUSettings[$settings.mode].CpuSupportsAVX)
    Add-Content $configFile1 ('CpuSupportsAVX2='    + $prime95CPUSettings[$settings.mode].CpuSupportsAVX2)
    Add-Content $configFile1 ('CpuSupportsFMA3='    + $prime95CPUSettings[$settings.mode].CpuSupportsFMA3)
    

    
    # Create the prime.txt and overwrite if necessary
    $null = New-Item $configFile2 -ItemType File -Force
    
    # Set the custom results.txt file name
    Set-Content $configFile2 ('results.txt=' + $primeResultsName)
    
    # Custom settings
    if ($configType -eq 'CUSTOM') {
        Add-Content $configFile2 ('TortureMem='    + $settings.customTortureMem)
        Add-Content $configFile2 ('TortureTime='   + $settings.customTortureTime)
    }
    
    # Default settings
    else {
        # No memory testing ("In-Place")
        # 1 minute per FFT size
        Add-Content $configFile2 'TortureMem=0'
        Add-Content $configFile2 'TortureTime=1'
    }

    # Set the FFT sizes
    Add-Content $configFile2 ('MinTortureFFT=' + $minFFTSize)
    Add-Content $configFile2 ('MaxTortureFFT=' + $maxFFTSize)
    

    # Get the correct TortureWeak setting
    Add-Content $configFile2 ('TortureWeak=' + $(Get-TortureWeakValue))
    
    Add-Content $configFile2 'V24OptionsConverted=1'
    Add-Content $configFile2 'WorkPreference=0'
    Add-Content $configFile2 'V30OptionsConverted=1'
    Add-Content $configFile2 'WGUID_version=2'
    Add-Content $configFile2 'StressTester=1'
    Add-Content $configFile2 'UsePrimenet=0'
    Add-Content $configFile2 'ExitOnX=1'
    Add-Content $configFile2 '[PrimeNet]'
    Add-Content $configFile2 'Debug=0'
}


<##
 # Open Prime95 and set global script variables
 # .PARAM void
 # .RETURN void
 #>
function Start-Prime95 {
    # Minimized to the tray
    $Script:process = Start-Process -filepath $primePath -ArgumentList '-t' -PassThru -WindowStyle Hidden
    
    # Minized to the task bar
    #$Script:process = Start-Process -filepath $primePath -ArgumentList '-t' -PassThru -WindowStyle Minimized

    # This might be necessary to correctly read the process. Or not
    Start-Sleep -Milliseconds 500
    
    if (!$Script:process) {
        Exit-WithFatalError('Could not start process ' + $processName + '!')
    }

    # Get the main window handler
    # This also works for windows minimized to the tray
    Get-Prime95WindowHandler
    
    # This is to find the exact counter path, as you might have multiple processes with the same name
    try {
        $Script:processCounterPath = ((Get-Counter "\Process(*)\ID Process" -ErrorAction SilentlyContinue).CounterSamples | ? {$_.RawValue -eq $processId}).Path
    }
    catch {
        #'Could not get the process path'
    }
}


<##
 # Close Prime95
 # .PARAM void
 # .RETURN void
 #>
function Close-Prime95 {
    # If there is no processWindowHandler id
    # Try to get it
    if (!$processWindowHandler) {
        Get-Prime95WindowHandler
    }
    
    # If we now have a processWindowHandler, try to close the window
    if ($processWindowHandler) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        
        # This returns false if no window is found with this handle
        if (![Win32]::SendMessage($processWindowHandler, [Win32]::WM_CLOSE, 0, 0) | Out-Null) {
            #'Process Window not found!'
        }

        # We've send the close request, let's wait up to 2 seconds
        elseif ($process -and !$process.HasExited) {
            #'Waiting for the exit'
            $null = $process.WaitForExit(3000)
        }
    }
    
    
    # If the window is still here at this point, just kill the process
    $process = Get-Process $processName -ErrorAction SilentlyContinue

    if ($process) {
        #'The process is still there, killing it'
        # Unfortunately this will leave any tray icons behind
        Stop-Process $process.Id -Force -ErrorAction SilentlyContinue
    }
}


<##
 # Check the CPU power usage and restart Prime95 if necessary
 # Throws an error if the CPU usage is too low
 # .PARAM int $coreNumber The current core being tested
 # .RETURN void
 #>
function Test-ProcessUsage {
    param (
        $coreNumber
    )
    
    # The minimum CPU usage for Prime95, below which it should be treated as an error
    # We need to account for the number of threads
    # Min. 1.5%
    # 100/32=   3,125% for 1 thread out of 32 threads
    # 100/32*2= 6,250% for 2 threads out of 32 threads
    # 100/24=   4,167% for 1 thread out of 24 threads
    # 100/24*2= 8,334% for 2 threads out of 24 threads
    # 100/12=   8,334% for 1 thread out of 12 threads
    # 100/12*2= 16,67% for 2 threads out of 12 threads
    $minPrimeUsage = [Math]::Max(1.5, $expectedUsage - [Math]::Round(100 / $numLogicalCores, 2))
    
    
    # Set to a string if there was an error
    $primeError = $false

    # Get the content of the result.txt file
    $resultFileHandle = Get-Item -Path $primeResultsPath -ErrorAction SilentlyContinue

    # Does the process still exist?
    $process = Get-Process $processName -ErrorAction SilentlyContinue
    

    # The process doesn't exist anymore, immediate error
    if (!$process) {
        $primeError = 'The Prime95 process doesn''t exist anymore.'
    }


    # Check if the process is still using enough CPU process power
    if (!$primeError) {
        # Get the CPU percentage
        $processCPUPercentage = [Math]::Round(((Get-Counter ($processCounterPath -replace "\\ID Process$","\% Processor Time") -ErrorAction SilentlyContinue).CounterSamples.CookedValue) / $numLogicalCores, 2)
        
        # It doesn't use enough CPU power, we assume that this core errored out
        # Try to restart Prime95
        if ($processCPUPercentage -le $minPrimeUsage) {
            # Try to read the error from Prime95's results.txt
            # Look for an "error" in the last 3 lines
            $primeResults = $resultFileHandle | Get-Content -Tail 3 | Where-Object {$_ -like '*error*'}

            # Found the "error" string
            if ($primeResults.Length -gt 0) {
                $primeError = $primeResults
            }

            # Error string not found
            # This might have been a false alarm, wait a bit and try again
            else {
                Start-Sleep -Milliseconds 1000

                # The second check
                # Do the whole process path procedure again
                $processId = $process.Id[0]
                $processCounterPath = ((Get-Counter "\Process(*)\ID Process" -ErrorAction SilentlyContinue).CounterSamples | ? {$_.RawValue -eq $processId}).Path
                $processCPUPercentage = [Math]::Round(((Get-Counter ($processCounterPath -replace "\\ID Process$","\% Processor Time") -ErrorAction SilentlyContinue).CounterSamples.CookedValue) / $numLogicalCores, 2)

                if ($processCPUPercentage -le $minPrimeUsage) {
                    # We don't care about an error string here anymore
                    $primeError = 'The Prime95 process doesn''t use enough CPU power anymore (only ' + $processCPUPercentage + '% instead of the expected ' + $expectedUsage + '%)'
                }
            }
        }
    }


    if ($primeError) {
        # Store the core number in the array
        $Script:coresWithError += $coreNumber

        # If Hyperthreading / SMT is enabled and the number of threads larger than 1
        if ($isHyperthreadingEnabled -and ($settings.numberOfThreads -gt 1)) {
            $cpuNumbersArray = @($coreNumber, ($coreNumber + 1))
            $cpuNumberString = (($cpuNumbersArray | sort) -join ' or ')
        }

        # Only one core is being tested
        else {
            # If Hyperthreading / SMT is enabled, the tested CPU number is 0, 2, 4, etc
            # Otherwise, it's the same value
            $cpuNumberString = $coreNumber * (1 + [Int]$isHyperthreadingEnabled)
        }


        # Try to close the Prime95 process if it is still running
        Close-Prime95
        
        
        # Put out an error message
        $timestamp = Get-Date -format HH:mm:ss
        Write-ColorText('ERROR: ' + $timestamp) Magenta
        Write-ColorText('ERROR: Prime95 seems to have stopped with an error!') Magenta
        Write-ColorText('ERROR: At Core ' + $coreNumber + ' (CPU ' + $cpuNumberString + ')') Magenta
        Write-ColorText('ERROR MESSAGE: ' + $primeError) Magenta
        
        # DEBUG
        # Also add the 5 last rows of the results.txt file
        #Write-Text('LAST 5 ROWS OF RESULTS.TXT:')
        #Write-Text(Get-Item -Path $primeResultsPath | Get-Content -Tail 5)
        
        # Try to determine the last run FFT size
        # If the result.txt doesn't exist, assume that it was on the very first iteration
        if (!$resultFileHandle) {
            $lastRunFFT = $minFFTSize
        }
        
        # Get the last couple of rows and find the last passed FFT size
        else {
            $lastFiveRows     = $resultFileHandle | Get-Content -Tail 5
            $lastPassedFFTArr = @($lastFiveRows | Where-Object {$_ -like '*passed*'})
            $hasMatched       = $lastPassedFFTArr[$lastPassedFFTArr.Length-1] -match 'Self-test (\d+)K passed'
            $lastPassedFFT    = [Int]$matches[1]   # $matches is a fixed(?) variable name for -match
            
            
            # TODO
            # If the last passed FFT size is the max selected FFT size, start at the beginning
            if ($lastPassedFFT -eq $maxFFTSize) {
                $lastRunFFT = $minFFTSize
            }

            # If the last passed FFT size is not the max size, check if the value doesn't show up at all in the FFT array
            # In this case, we also assume that it successfully completed the max value and errored at the min FFT size
            # Example: Smallest FFT max = 21, but the actual last size tested is 20K
            elseif (!$FFTSizes[$cpuTestMode].Contains($lastPassedFFT)) {
                $lastRunFFT = $minFFTSize
            }

            # If it's not the max value and it does show up in the FFT array, select the next value
            else {
                $lastRunFFT = $FFTSizes[$cpuTestMode][$FFTSizes[$cpuTestMode].indexOf($lastPassedFFT)+1]
            }
        }
        
        # Educated guess
        if ($lastRunFFT) {
            Write-ColorText('ERROR: The error likely happened at FFT size ' + $lastRunFFT + 'K') Magenta
        }
        

        # Try to restart Prime95 and continue with the next core
        Write-Text('Trying to restart Prime95')
        
        
        # Start Prime95 again
        Start-Prime95
        
        
        # Throw an error to let the caller know there was an error
        throw 'Prime95 seems to have stopped with an error at Core ' + $coreNumber + ' (CPU ' + $cpuNumberString + ')'
    }
}



<##
 # The main functionality
 #>
# Get the default and user settings
Get-Settings


# The number of physical and logical cores
# This also includes hyperthreading resp. SMT (Simultaneous Multi-Threading)
# We currently only test the first core for each hyperthreaded "package",
# so e.g. only 12 cores for a 24 threaded Ryzen 5900x
# If you disable hyperthreading / SMT, both values should be the same
$processor       = Get-WMIObject Win32_Processor
$numLogicalCores = $($processor | Measure-Object -Property NumberOfLogicalProcessors -sum).Sum
$numPhysCores    = $($processor | Measure-Object -Property NumberOfCores -sum).Sum


# Set the flag if Hyperthreading / SMT is enabled or not
$isHyperthreadingEnabled = ($numLogicalCores -gt $numPhysCores)


# The Prime95 executable name and path
$processName = 'prime95'
$processPath = $PSScriptRoot + '\p95\'
$primePath   = $processPath + $processName


# The Prime95 process
$process = Get-Process $processName -ErrorAction SilentlyContinue


# The expected CPU usage for the running Prime95 process
# The selected number of threads should be at 100%, so e.g. for 1 thread out of 24 threads this is 100/24*1= 4.17%
# Used to determine if Prime95 is still running or has thrown an error
$expectedUsage = [Math]::Round(100 / $numLogicalCores * $settings.numberOfThreads, 2)


# Store all the cores that have thrown an error in Prime95
# These cores will be skipped on the next iteration
[Int[]] $coresWithError = @()


# Check the CPU usage each x seconds
$cpuUsageCheckInterval = 30


# Calculate the interval time for the CPU power check
$cpuCheckIterations = [Math]::Floor($settings.runtimePerCore / $cpuUsageCheckInterval)
$runtimeRemaining   = $settings.runtimePerCore - ($cpuCheckIterations * $cpuUsageCheckInterval)


# The Prime95 CPU settings for the various test modes
$prime95CPUSettings = @{
    SSE = @{
        CpuSupportsSSE  = 1
        CpuSupportsSSE2 = 1
        CpuSupportsAVX  = 0
        CpuSupportsAVX2 = 0
        CpuSupportsFMA3 = 0
    }

    AVX = @{
        CpuSupportsSSE  = 1
        CpuSupportsSSE2 = 1
        CpuSupportsAVX  = 1
        CpuSupportsAVX2 = 0
        CpuSupportsFMA3 = 0
    }

    AVX2 = @{
        CpuSupportsSSE  = 1
        CpuSupportsSSE2 = 1
        CpuSupportsAVX  = 1
        CpuSupportsAVX2 = 1
        CpuSupportsFMA3 = 1
    }

    CUSTOM = @{
        CpuSupportsSSE  = 1
        CpuSupportsSSE2 = 1
        CpuSupportsAVX  = $settings.customCpuSupportsAVX
        CpuSupportsAVX2 = $settings.customCpuSupportsAVX2
        CpuSupportsFMA3 = $settings.customCpuSupportsFMA3
    }
}


# The various FFT sizes
# Used to determine where an error likely happened
# Note: These are different depending on the selected mode (SSE, AVX, AVX2)!
# AVX2: 4, 5, 6, 8, 10, 12, 15, 16, 18, 20, 21, 24, 25, 28, 30, 32, 35, 36, 40, 48, 50, 60, 64, 72, 80, 84, 96, 100, 112, 120, 128,      144, 160, 168, 192, 200, 224, 240, 256, 280, 288, 320, 336, 384, 400, 448, 480, 512, 560,      640, 672,      768, 800,      896, 960, 1024, 1120, 1152,       1280, 1344, 1440, 1536, 1600, 1680,       1792, 1920, 2048, 2240, 2304, 2400, 2560, 2688, 2800, 2880, 3072, 3200, 3360,       3584, 3840,       4096, 4480, 4608, 4800, 5120, 5376, 5600, 5760, 6144, 6400, 6720,       7168, 7680, 8000, 8064, 8192
# AVX:  4, 5, 6, 8, 10, 12, 15, 16, 18, 20, 21, 24, 25, 28,     32, 35, 36, 40, 48, 50, 60, 64, 72, 80, 84, 96, 100, 112, 120, 128, 140, 144, 160, 168, 192, 200, 224, 240, 256,      288, 320, 336, 384, 400, 448, 480, 512, 560, 576, 640, 672, 720, 768, 800, 864, 896, 960, 1024,       1152,       1280, 1344, 1440, 1536, 1600, 1680, 1728, 1792, 1920, 2048,       2304, 2400, 2560, 2688,       2880, 3072, 3200, 3360, 3456, 3584, 3840, 4032, 4096, 4480, 4608, 4800, 5120, 5376,       5760, 6144, 6400, 6720, 6912, 7168, 7680, 8000,       8192
# SSE:  4, 5, 6, 8, 10, 12, 14, 16,     20,     24,     28,     32,         40, 48, 56,     64, 72, 80, 84, 96,      112,      128,      144, 160,      192,      224, 240, 256,      288, 320, 336, 384, 400, 448, 480, 512, 560, 576, 640, 672, 720, 768, 800,      896, 960, 1024, 1120, 1152, 1200, 1280, 1344, 1440, 1536, 1600, 1680, 1728, 1792, 1920, 2048, 2240, 2304, 2400, 2560, 2688, 2800, 2880, 3072, 3200, 3360, 3456, 3584, 3840,       4096, 4480, 4608, 4800, 5120, 5376, 5600, 5760, 6144, 6400, 6720, 6912, 7168, 7680, 8000,       8192
$FFTSizes = @{
    SSE = @(
        # Smallest FFT
        4, 5, 6, 8, 10, 12, 14, 16, 20,
        
        # Not used in Prime95 presets
        24, 28, 32,
        
        # Small FFT
        40, 48, 56, 64, 72, 80, 84, 96, 112, 128, 144, 160, 192, 224, 240,

        # Not used in Prime95 presets
        256, 288, 320, 336, 384, 400,

        # Large FFT
        448, 480, 512, 560, 576, 640, 672, 720, 768, 800, 896, 960, 1024, 1120, 1152, 1200, 1280, 1344, 1440, 1536, 1600, 1680, 1728, 1792, 1920,
        2048, 2240, 2304, 2400, 2560, 2688, 2800, 2880, 3072, 3200, 3360, 3456, 3584, 3840, 4096, 4480, 4608, 4800, 5120, 5376, 5600, 5760, 6144,
        6400, 6720, 6912, 7168, 7680, 8000, 8192
    )

    AVX = @(
        # Smallest FFT
        4, 5, 6, 8, 10, 12, 15, 16, 18, 20, 21,

        # Not used in Prime95 presets
        24, 25, 28, 32, 35,

        # Small FFT
        36, 40, 48, 50, 60, 64, 72, 80, 84, 96, 100, 112, 120, 128, 140, 144, 160, 168, 192, 200, 224, 240,

        # Not used in Prime95 presets
        256, 288, 320, 336, 384, 400,

        # Large FFT
        448, 480, 512, 560, 576, 640, 672, 720, 768, 800, 864, 896, 960, 1024, 1152, 1280, 1344, 1440, 1536, 1600, 1680, 1728, 1792, 1920,
        2048, 2304, 2400, 2560, 2688, 2880, 3072, 3200, 3360, 3456, 3584, 3840, 4032, 4096, 4480, 4608, 4800, 5120, 5376, 5760, 6144,
        6400, 6720, 6912, 7168, 7680, 8000, 8192
    )


    AVX2 = @(
        # Smallest FFT
        4, 5, 6, 8, 10, 12, 15, 16, 18, 20, 21,

        # Not used in Prime95 presets
        24, 25, 28, 30, 32, 35,

        # Small FFT
        36, 40, 48, 50, 60, 64, 72, 80, 84, 96, 100, 112, 120, 128, 144, 160, 168, 192, 200, 224, 240,

        # Not used in Prime95 presets
        256, 280, 288, 320, 336, 384, 400,

        # Large FFT
        448, 480, 512, 560, 640, 672, 768, 800, 896, 960, 1024, 1120, 1152, 1280, 1344, 1440, 1536, 1600, 1680, 1792, 1920,
        2048, 2240, 2304, 2400, 2560, 2688, 2800, 2880, 3072, 3200, 3360, 3584, 3840, 4096, 4480, 4608, 4800, 5120, 5376, 5600, 5760, 6144,
        6400, 6720, 7168, 7680, 8000, 8064, 8192
    )
}


# The min and max values for the various presets
# Note that the actually tested sizes differ from the originally provided min and max values
# depending on the selected test mode (SSE, AVX, AVX2)
$FFTMinMaxValues = @{
    SSE = @{
        Smallest = @{ Min =   4; Max =   20; }  # Originally   4 ...   21
        Small    = @{ Min =  40; Max =  240; }  # Originally  36 ...  248
        Large    = @{ Min = 448; Max = 8192; }  # Originally 426 ... 8192
        All      = @{ Min =   4; Max = 8192; }  # Originally   4 ... 8192
    }

    AVX = @{
        Smallest = @{ Min =   4; Max =   21; }  # Originally   4 ...   21
        Small    = @{ Min =  36; Max =  240; }  # Originally  36 ...  248
        Large    = @{ Min = 448; Max = 8192; }  # Originally 426 ... 8192
        All      = @{ Min =   4; Max = 8192; }  # Originally   4 ... 8192
    }

    AVX2 = @{
        Smallest = @{ Min =   4; Max =   21; }  # Originally   4 ...   21
        Small    = @{ Min =  36; Max =  240; }  # Originally  36 ...  248
        Large    = @{ Min = 448; Max = 8192; }  # Originally 426 ... 8192
        All      = @{ Min =   4; Max = 8192; }  # Originally   4 ... 8192
    }
}


# Get the correct min and max values for the selected FFT settings
if ($settings.mode -eq 'CUSTOM') {
    $minFFTSize = [Int]$settings.customMinTortureFFT
    $maxFFTSize = [Int]$settings.customMaxTortureFFT
}
else {
    $minFFTSize = $FFTMinMaxValues[$settings.mode][$settings.FFTSize].Min
    $maxFFTSize = $FFTMinMaxValues[$settings.mode][$settings.FFTSize].Max
}


# Get the test mode, even if $settings.mode is set to CUSTOM
$cpuTestMode = $settings.mode

# If we're in CUSTOM mode, try to determine which setting preset it is
if ($settings.mode -eq 'CUSTOM') {
    $cpuTestMode = 'SSE'

    if ($settings.customCpuSupportsAVX -eq 1) {
        if ($settings.customCpuSupportsAVX2 -eq 1 -and $settings.customCpuSupportsFMA3 -eq 1) {
            $cpuTestMode = 'AVX2'
        }
        else {
            $cpuTestMode = 'AVX'
        }
    }
}


# The Prime95 results.txt file name for this run
$primeResultsName = 'results_CoreCycler_' + $curDateTime + '_' + $settings.mode + '_FFT_' + $minFFTSize + 'K-' + $maxFFTSize + 'K.txt'
$primeResultsPath = $processPath + $primeResultsName



# Close all existing instances of Prime95 and start a new one with our config
if ($process) {
    Close-Prime95
}

# Create the config file
Initialize-Prime95 $settings.mode

# Start Prime95
Start-Prime95


# Get the current datetime
$timestamp = Get-Date -format u


# Start messages
Write-ColorText('---------------------------------------------------------------------------') Green
Write-ColorText('CoreCycler startet at ' + $timestamp) Green
Write-ColorText('---------------------------------------------------------------------------') Green

# Display the number of logical & physical cores
Write-ColorText('Found ' + $numLogicalCores + ' logical and ' + $numPhysCores + ' physical cores') Cyan
Write-ColorText('Hyperthreading / SMT is: ' + ($(if ($isHyperthreadingEnabled) { 'ON' } else { 'OFF' }))) Cyan
Write-ColorText('Selected number of threads: ' + $settings.numberOfThreads) Cyan
Write-ColorText('Number of iterations: ' + $settings.maxIterations) Cyan

# And the selected mode (SSE, AVX, AVX2)
Write-ColorText('Selected mode: ' + $settings.mode) Cyan

if ($settings.mode -eq 'CUSTOM') {
    Write-ColorText('Custom settings:') Cyan
    Write-ColorText('CpuSupportsAVX  = ' + $settings.customCpuSupportsAVX) Cyan
    Write-ColorText('CpuSupportsAVX2 = ' + $settings.customCpuSupportsAVX2) Cyan
    Write-ColorText('CpuSupportsFMA3 = ' + $settings.customCpuSupportsFMA3) Cyan
    Write-ColorText('MinTortureFFT   = ' + $settings.customMinTortureFFT) Cyan
    Write-ColorText('MaxTortureFFT   = ' + $settings.customMaxTortureFFT) Cyan
    Write-ColorText('TortureMem      = ' + $settings.customTortureMem) Cyan
    Write-ColorText('TortureTime     = ' + $settings.customTortureTime) Cyan
}
else {
    Write-ColorText('Selected FFT size: ' + $settings.FFTSize + ' (' + $minFFTSize + 'K - ' + $maxFFTSize + 'K)') Cyan
}

Write-ColorText('---------------------------------------------------------------------------') Cyan


# Print a message if we're ignoring certain cores
if ($settings.coresToIgnore.Length -gt 0) {
    $settings.coresToIgnoreString = (($settings.coresToIgnore | sort) -join ', ')
    Write-ColorText('Ignored cores: ' + $settings.coresToIgnoreString) Cyan
    #Write-ColorText('---------------' + ('-' * $settings.coresToIgnoreString.Length)) Cyan
    Write-ColorText('---------------------------------------------------------------------------') Cyan
}


# Display the results.txt file name for Prime95 for this run
Write-ColorText('Prime95''s results are being stored in:') Cyan
Write-ColorText($primeResultsPath) Cyan

# And the name of the log file for this run
Write-ColorText('') Cyan
Write-ColorText('The path of the CoreCycler log file is:') Cyan
Write-ColorText($logfilePath) Cyan


# Try to get the affinity of the Prime95 process. If not found, abort
try {
    $null = $process.ProcessorAffinity
    #Write-Text('Current affinity of process: ' + $process.ProcessorAffinity)
}
catch {
    Exit-WithFatalError('Process ' + $processName + ' not found!')
}



# Repeat the whole check $settings.maxIterations times
for ($iteration = 1; $iteration -le $settings.maxIterations; $iteration++) {
    $timestamp = Get-Date -format HH:mm:ss

    # Check if all of the cores have thrown an error, and if so, abort
    if ($coresWithError.Length -eq ($numPhysCores - $settings.coresToIgnore.Length)) {
        # Also close the Prime95 process to not let it run unnecessarily
        Close-Prime95
        
        Write-Text($timestamp + ' - All Cores have thrown an error, aborting!')
        Read-Host -Prompt 'Press Enter to exit'
        exit
    }


    Write-ColorText('') Yellow
    Write-ColorText($timestamp + ' - Iteration ' + $iteration) Yellow
    Write-ColorText('----------------------------------') Yellow
    
    # Iterate over each core
    # Named for loop
    :coreLoop for ($coreNumber = 0; $coreNumber -lt $numPhysCores; $coreNumber++) {
        $startDateThisCore = (Get-Date)
        $endDateThisCore   = $startDateThisCore + (New-TimeSpan -Seconds $settings.runtimePerCore)
        $timestamp         = $startDateThisCore.ToString("HH:mm:ss")
        $affinity          = 0
        $cpuNumbersArray   = @()


        # Get the current CPU core(s)

        # If the number of threads is more than 1
        if ($settings.numberOfThreads -gt 1) {
            for ($currentThread = 0; $currentThread -lt $settings.numberOfThreads; $currentThread++) {
                # We don't care about Hyperthreading / SMT here, it needs to be enabled for 2 threads
                $thisCPUNumber    = ($coreNumber * 2) + $currentThread
                $cpuNumbersArray += $thisCPUNumber
                $affinity        += [Math]::Pow(2, $thisCPUNumber)
            }
        }

        # Only one thread
        else {
            # If Hyperthreading / SMT is enabled, the tested CPU number is 0, 2, 4, etc
            # Otherwise, it's the same value
            $cpuNumber        = $coreNumber * (1 + [Int]$isHyperthreadingEnabled)
            $cpuNumbersArray += $cpuNumber
            $affinity         = [Math]::Pow(2, $cpuNumber)
        }

        $cpuNumberString = (($cpuNumbersArray | sort) -join ' and ')


        # If this core is in the ignored cores array
        if ($settings.coresToIgnore -contains $coreNumber) {
            # Ignore it silently
            #Write-Text($timestamp + ' - Core ' + $coreNumber + ' (CPU ' + $cpuNumberString + ') is being ignored, skipping')
            continue
        }

        # If this core is stored in the error core array
        if ($coresWithError -contains $coreNumber) {
            Write-Text($timestamp + ' - Core ' + $coreNumber + ' (CPU ' + $cpuNumberString + ') has previously thrown an error, skipping')
            continue
        }


        # If $settings.restartPrimeForEachCore is set, restart Prime95 for each core
        # TODO: this check will not work correctly if core 0 is added to the $settings.coresToIgnore array
        if ($settings.restartPrimeForEachCore -and ($iteration -gt 1 -or $coreNumber -gt 0)) {
            Close-Prime95
            Start-Prime95
        }
        
       
        # This core has not thrown an error yet, run the test
        Write-Text($timestamp + ' - Set to Core ' + $coreNumber + ' (CPU ' + $cpuNumberString + ')')
        
        # Set the affinity to a specific core
        try {
            $process.ProcessorAffinity = [System.IntPtr][Int]$affinity
            Write-Text('Running for ' + (Get-FormattedRuntimePerCoreString $settings.runtimePerCore) + '...')
        }
        catch {
            Close-Prime95
            Exit-WithFatalError('Could not set the affinity to Core ' + $coreNumber + ' (CPU ' + $cpuNumberString + ')!')
        }


        # Make a check each x seconds for the CPU power usage
        for ($checkNumber = 0; $checkNumber -lt $cpuCheckIterations; $checkNumber++) {
            $nowDateTime = (Get-Date)
            $difference  = New-TimeSpan -Start $nowDateTime -End $endDateThisCore


            # Make this the last iteration if the remaining time is close enough
            if ($difference.TotalSeconds -le $cpuUsageCheckInterval) {
                $checkNumber = $cpuCheckIterations
                Start-Sleep -Seconds ($difference.TotalSeconds - 1)
            }
            else {
                Start-Sleep -Seconds $cpuUsageCheckInterval
            }
            

            # Check if the process is still using enough CPU process power
            try {
                Test-ProcessUsage $coreNumber
            }
            
            # On error, the Prime95 process is not running anymore, so skip this core
            catch {
                continue coreLoop
            }
        
        }
        
        # Wait for the remaining runtime
        Start-Sleep -Seconds $runtimeRemaining
        
        # One last check
        try {
            Test-ProcessUsage $coreNumber
        }
        
        # On error, the Prime95 process is not running anymore, so skip this core
        catch {
            continue
        }
    }
    
    
    # Print out the cores that have thrown an error so far
    if ($coresWithError.Length -gt 0) {
        Write-Text('The following cores have thrown an error: ' + (($coresWithError | sort) -join ', '))
    }
}


# The CoreCycler has finished
$timestamp = Get-Date -format HH:mm:ss
Write-Text($timestamp + ' - CoreCycler finished')
Close-Prime95
Read-Host -Prompt 'Press Enter to exit'