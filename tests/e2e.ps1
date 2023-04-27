#Requires -RunAsAdministrator

# End2End tests for AksEdge.
# Note, execute this script w/ execution policy in bypass / disabled / signed, because these tests
# rely on Uninstall-Eflow.ps1 to clean up device state in between test cases.

param(
    [Switch]
    # Flag to list all known test cases
    $List,

    [Parameter(ParameterSetName='All')]
    [Switch]
    # Indicates that all test cases are to be processed
    $All,

    [Parameter(ParameterSetName='OptInGroup')]
    [String[]]
    # For the test run, opt-in to specific groups
    $IncludeGroup,

    [Parameter(ParameterSetName='OptInTest')]
    [String[]]
    # For the test run, opt-in to specific tests
    $IncludeTest,

    [Parameter(ParameterSetName='OptOutGroup')]
    [String[]]
    # For the test run, run all tests except those matching these groups
    $ExcludeGroup,

    [Parameter(ParameterSetName='OptOutTest')]
    [String[]]
    # For the test run, run all tests except those matching these tests
    $ExcludeTest,

    [HashTable]
    # Pass variables into tests
    $TestVar,

    [String]
    # Log results into this file (JUnit format)
    $LogFile
)

# Define a custom exception class to capture test failures (assert failures should raise this, etc.)
class TestFailure : Exception
{
    TestFailure($Message) : base($Message)
    {
    }
}

function Raise-TestFailure
{
    param
    (
        [string]
        $Message
    )

    throw [TestFailure]::new($Message)
}

function Assert-Equal
{
    param
    (
        $Left,
        $Right
    )

    if ($Left -ne $Right)
    {
        Raise-TestFailure "Assert-Equal ($Left) == ($Right) failed"
    }
}

$AideModulePath = "$PSScriptRoot\..\tools"

$JsonTestParameters = Get-Content -Raw $AideModulePath\aide-userconfig.json

$aksedgeShell = (Get-ChildItem -Path "$AideModulePath" -Filter AksEdgeShell.ps1 -Recurse).FullName
. $aksedgeShell

# Import all test modules here.
#
# All tests are named as follows:
# E2eTest-GroupName-TestName or E2eTest-TestName
#
# Get-Command is used to locate test cases
#
# Test groups can have Setup-GroupName, Cleanup-GroupName functions defined
# that are run before and after each test case function respectively

. "$PSScriptRoot\E2E\e2e_basiclinuxoffline_test.ps1"
. "$PSScriptRoot\E2E\e2e_basiclinuxonline_test.ps1"

# Put all commands into $CommandTree, which is a map(GroupName => Array(FunctionNames))
$AllCommands = Get-Command -Verb 'E2eTest'
$CommandTree = [ordered]@{}

foreach ($Command in $AllCommands)
{
    # Command can match either E2eTest-(GroupName)-(TestCase) or
    # E2eTest-(TestCase) (in which case the group name is "NoGroup")

    $GroupName = "NoGroup"

    if ($Command.Name -match "^E2eTest-(\w+)-\w+$") {
        $GroupName = $Matches[1]
    }

    $CommandTree[$GroupName] += @($Command.Name)
}

Write-Host "Group: $IncludeGroup"
Write-Host "Groups: $CommandTree"

# Test results is an array consisting tuples (name, group, time, result, message)
$TestStartTime = Get-Date
$TestResults = [System.Collections.ArrayList]::new()
$TestErrorCount = 0
$TestFailureCount = 0
$TestTotalCount = 0
$TestTotalTime = [TimeSpan]0
$TestStartTime = Get-Date

function Log-TestPass
{
    param
    (
        [string]
        $Name,

        [string]
        $Group
    )

    $ElapsedTime = (Get-Date) - $TestStartTime
    $script:TestTotalTime += $ElapsedTime
    Write-Host "!!END $Name : PASS"

    $Result = @{
        Name = $Name
        Group = $Group
        Time = $ElapsedTime.TotalSeconds
        Result = 'pass'
    }

    [void] $script:TestResults.Add($Result)
}

function Log-TestError
{
    param
    (
        [string]
        $Name,

        [string]
        $Group,

        [string]
        $Message
    )

    $ElapsedTime = (Get-Date) - $TestStartTime
    $script:TestTotalTime += $ElapsedTime
    Write-Host "!!END $Name : ERROR : $Message"

    $Result = @{
        Name = $Name
        Group = $Group
        Time = $ElapsedTime.TotalSeconds
        Result = 'error'
        Message = $Message
    }

    [void] $script:TestResults.Add($Result)
    ++$script:TestErrorCount
}

Function Log-TestFailure
{
    param
    (
        [string]
        $Name,

        [string]
        $Group,

        [string]
        $Message
    )

    $ElapsedTime = (Get-Date) - $script:TestStartTime
    $script:TestTotalTime += $ElapsedTime
    Write-Host "!!END $Name : FAILED : $Message"

    $Result = @{
        Name = $Name
        Group = $Group
        Time = $ElapsedTime.TotalSeconds
        Result = 'failure'
        Message = $Message
    }

    [void] $script:TestResults.Add($Result)
    ++$script:TestFailureCount
}

# Execute the tests

:NextGroup foreach ($GroupName in ($CommandTree.Keys))
{
    # Group level filtering
    switch ($PsCmdlet.ParameterSetName)
    {
        # Filter in / out based on group name
        'OptInGroup'
        {
            $Found = $false
            foreach ($IncludedGroupPattern in $IncludeGroup)
            {
                if ($GroupName -like $IncludedGroupPattern)
                {
                    $Found = $true
                    break
                }
            }

            if (-Not $Found)
            {
                continue NextGroup
            }
        }

        'OptOutGroup'
        {
            foreach ($ExcludedGroupPattern in $ExcludeGroup)
            {
                if ($GroupName -like $ExcludedGroupPattern)
                {
                    continue NextGroup
                }
            }
        }
    }

    Write-Host "!!Group: $GroupName"

    # Find cleanup / setup functions for execution
    $SetupFunctionName = "Setup-$GroupName"
    try
    {
        Get-Command -Name $SetupFunctionName | Out-Null
    }
    catch
    {
        Write-Verbose "!!No setup function for $GroupName"
        $SetupFunctionName = ""
    }

    $CleanupFunctionName = "Cleanup-$GroupName"
    try
    {
        Get-Command -Name $CleanupFunctionName | Out-Null
    }
    catch
    {
        Write-Verbose "!!No cleanup function for $GroupName"
        $CleanupFunctionName = ""
    }

    if (-Not $List.IsPresent)
    {
        # Call the setup function if it exists
	    try
	    {
            if (-Not [string]::IsNullOrEmpty($SetupFunctionName))
            {
                Write-Host "!!  Calling $SetupFunctionName"
                & $SetupFunctionName -JsonTestParameters $JsonTestParameters -TestVar $TestVar 
            }
	    }
	    catch
	    {
            $Message = "Test Setup Failed: $($PSItem)`n$($PSItem.ScriptStackTrace)"
            Log-TestError -Name "Setup" -Group $GroupName -Message $Message
		    continue
	    }
    }

    # Iterate into the group and process
    :NextTest foreach ($TestName in ($CommandTree[$GroupName]))
    {
        # Filter in / out based on test name
        switch ($PsCmdlet.ParameterSetName)
        {
            'OptInTest'
            {
                $Found = $false
                foreach ($IncludedTestPattern in $IncludeTest)
                {
                    if ($TestName -like $IncludedTestPattern)
                    {
                        $Found = $true;
                        break
                    }
                }

                if (-Not $Found)
                {
                    continue NextTest
                }
            }

            'OptOutTest'
            {
                foreach ($ExcludedTestPattern in $ExcludeTest)
                {
                    if ($TestName -like $ExcludedTestPattern)
                    {
                        continue NextTest
                    }
                }
            }
        }

        # Got Past test filtering

        if ($List.IsPresent)
        {
            # Print the name if only listing
            Write-Host "!!  $TestName"
        }
        else
        {
            Write-Host "!!BEGIN $TestName"
            ++$TestTotalCount

            # If executing:
            #
            # Snap time at test start
            $TestStartTime = Get-Date
            $SuccessfulRun = $False

            # Call the test function
            try
            {
                & $TestName -JsonTestParameters $JsonTestParameters -TestVar $TestVar | Out-Null
                $SuccessfulRun = $True
            }
            # Otherwise turn caught exceptions into either failures / errors
            catch [TestFailure]
            {
                $Message = "$($PSItem.Exception.Message)`n$($PSItem.ScriptStackTrace)"
                Log-TestFailure -Name $TestName -Group $GroupName -Message $Message
            }
            catch
            {
                $Message = "$($PSItem)`n$($PSItem.ScriptStackTrace)"
                Log-TestError -Name $TestName -Group $GroupName -Message $Message
            }

            # Log success after test run
            if ($SuccessfulRun)
            {
                Log-TestPass -Name $TestName -Group $GroupName
            }
        }
    }

    # Call the cleanup function if it exists
    try
    {
        if (-Not [string]::IsNullOrEmpty($CleanupFunctionName))
        {
            Write-Host "!!  Calling $CleanupFunctionName"
            & $CleanupFunctionName -AideUserConfigPath $PSScriptRoot\..\tools\aide-userconfig.json | Out-Null
        }
    }
	catch
	{
        $Message = "Test Cleanup Failed: $($PSItem)`n$($PSItem.ScriptStackTrace)"
        Log-TestError -Name $TestName -Group $GroupName -Message $Message
        continue
    }

    if (-Not $List.IsPresent)
    {
        Write-Host "!! Tests: $TestTotalCount, Time: $($TestTotalTime.TotalSeconds) Errors: $TestErrorCount, Failures: $TestFailureCount"
        if ($TestErrorCount -gt 0 -Or $TestFailureCount -gt 0)
        {
            Write-Host "!! Failed Test Cases:"
            foreach ($TestCase in $TestResults)
            {
                if ($TestCase['Result'] -ceq "failure" -Or $TestCase['Result'] -ceq "error")
                {
                    Write-Host "!! Test: $($TestCase['Name']) State: $($TestCase['Result']) Message: $($TestCase['Message'])"
                }
            }
        }

        if ((-Not $List.IsPresent) -And (-Not [string]::IsNullOrEmpty($LogFile)))
        {
            Write-Host "!! Logging to $LogFile, format = Junit"

            $XmlSettings = [System.Xml.XmlWriterSettings]::new()
            $XmlSettings.Indent = $True
            $XmlSettings.IndentChars = '  '
            $XmlSettings.NewLineOnAttributes = $True

            $XmlWriter = [System.Xml.XmlWriter]::Create($LogFile, $XmlSettings)

            $XmlWriter.WriteStartDocument()

            # <testsuite>
            $XmlWriter.WriteStartElement("testsuite")
            $XmlWriter.WriteStartAttribute("name")
            $XmlWriter.WriteString("AksIot-E2E-Tests")
            $XmlWriter.WriteEndAttribute()

            $XmlWriter.WriteStartAttribute("time")
            $XmlWriter.WriteString($TestTotalTime.TotalSeconds)
            $XmlWriter.WriteEndAttribute()

            $XmlWriter.WriteStartAttribute("timestamp")
            $XmlWriter.WriteString($TestStartTime.ToString("s"))
            $XmlWriter.WriteEndAttribute()

            $XmlWriter.WriteStartAttribute("errors")
            $XmlWriter.WriteString("$TestErrorCount")
            $XmlWriter.WriteEndAttribute()

            $XmlWriter.WriteStartAttribute("failures")
            $XmlWriter.WriteString("$TestFailureCount")
            $XmlWriter.WriteEndAttribute()

            $XmlWriter.WriteStartAttribute("tests")
            $XmlWriter.WriteString("$TestTotalCount")
            $XmlWriter.WriteEndAttribute()

            foreach ($TestCase in $TestResults)
            {
                # <testcase>
                $XmlWriter.WriteStartElement("testcase")

                $XmlWriter.WriteStartAttribute("classname")
                $XmlWriter.WriteString($($TestCase['Group']))
                $XmlWriter.WriteEndAttribute()

                $XmlWriter.WriteStartAttribute("name")
                $XmlWriter.WriteString($($TestCase['Name']))
                $XmlWriter.WriteEndAttribute()

                $XmlWriter.WriteStartAttribute("time")
                $XmlWriter.WriteString($($TestCase['Time']))
                $XmlWriter.WriteEndAttribute()

                if ($TestCase['Result'] -ceq "failure" -or $TestCase['Result'] -ceq "error")
                {
                    # <failure> or <error>
                    $XmlWriter.WriteStartElement($($TestCase['Result']))
                    $XmlWriter.WriteString($($TestCase['Message']))
                    $XmlWriter.WriteEndElement()
                    # </failure> or <error>
                }

                # </testcase>
                $XmlWriter.WriteEndElement()
            }

            # </testsuite>
            $XmlWriter.WriteEndElement()
            $XmlWriter.WriteEndDocument()

            # Finished, write out the file
            $XmlWriter.Close()
        }
    }
}
