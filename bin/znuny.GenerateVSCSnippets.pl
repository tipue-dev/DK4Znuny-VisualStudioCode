#!/usr/bin/perl
# --
# Copyright (C) 2012-2017 Znuny GmbH, http://znuny.com/
# Copyright (C) 2023 Denny Korsukéwitz, https://github.com/dennykorsukewitz
# --
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU AFFERO General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA
# or see http://www.gnu.org/licenses/agpl.txt.
# --

use strict;
use warnings;

use File::Basename;
use FindBin qw($RealBin);
use lib dirname($RealBin);
use lib dirname($RealBin) . '/Kernel/cpan-lib';
use lib dirname($RealBin) . '/Custom';

use Kernel::System::ObjectManager;
use Kernel::System::VariableCheck qw(:all);
use bin::ZnunyPODParser;

use Term::ANSIColor();
use Data::Dumper;
use Getopt::Long();
use List::MoreUtils qw(uniq);
use File::Path qw( make_path );

local $Kernel::OM = Kernel::System::ObjectManager->new(
    'Kernel::System::Log' => {
        LogPrefix => 'znuny.GenerateVSCSnippets.pl',
    },
);

my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
my $MainObject   = $Kernel::OM->Get('Kernel::System::Main');
my $JSONObject   = $Kernel::OM->Get('Kernel::System::JSON');
my $LogObject    = $Kernel::OM->Get('Kernel::System::Log');

my $Home        = $ConfigObject->Get('Home');
my $Version     = $ConfigObject->Get('Version');
my $TemplateDir = $ConfigObject->Get('TemplateDir');

my $PackageDir = dirname(readlink(__FILE__));
$PackageDir =~ s{/bin}{}xms;

$Version = ValidateVersion($Version);

my ( $DryRun, $GetOptVersion, $Help, @ContributesSnippetsData, $ContributesSnippetsDataFile, %RawData, $RawDataFile, %SkippedRawData, $SkippedRawDataFile);

my @Modules = (
    'AgentTicket', 'CustomerTicket',
);

# read files only in this dir (no Recursive)
my @Directories  = (
    '/Kernel/GenericInterface',
    '/Kernel/System',
    '/Kernel/System/GenericInterface',
    '/Kernel/System/ProcessManagement',
    '/Kernel/System/Scheduler',
    '/Kernel/System/UnitTest',
);

# add these single files instead of whole directories
my @Files  = (
    '/Kernel/Config.pod.dist',
    '/Kernel/Language.pm',
    '/Kernel/Output/HTML/Layout.pm',
    '/Kernel/System/Daemon/SchedulerDB.pm',
    '/Kernel/System/DynamicField/Backend.pm',
    '/Kernel/System/Ticket/Article.pm',
    '/Kernel/System/Web/Request.pm',
    '/Kernel/System/Web/UploadCache.pm',
);

my @LayoutObjectFiles = $MainObject->DirectoryRead(
    Directory => $TemplateDir . '/HTML/Layout',
    Filter    => '*.pm',
);

# use this to add additional perl modules to an existing object.
# make sure that the object is present in the @Files or @Directories.
# e.g. TicketObject => /Kernel/System/Ticket.pm
# loaded by @Directories('/Kernel/System');
# The submodules should not be loaded via @Files or @Directories.
my %ObjectFilesMapping = (
    TicketObject => [
        $Home . '/Kernel/System/Ticket/TicketSearch.pm',
        $Home . '/Kernel/System/Ticket/TicketACL.pm',
    ],
    LayoutObject => [
        @LayoutObjectFiles,
    ],
    UnitTestObject => [
        $Home . '/Kernel/System/UnitTest/Driver.pm',
    ],
);

# change CallObject name to other

# example:
# changed
#   $UnitTestObject->False(1, 'Test Name');
# to
#   $Self->False(1, 'Test Name');

my %CallObjectMapping = (
    UnitTestObject => 'Self',
    Helper         => 'HelperObject',
);

# skip this files
my @FileBlacklist = (
    '/Kernel/System/OTRSBusiness.pm',
    '/Kernel/System/CloudService.pm',
    '/Kernel/System/Registration.pm',

    '/Kernel/System/EventHandler.pm',
    '/Kernel/System/VariableCheck.pm',
    '/Kernel/System/ObjectManager.pm',

    '/Kernel/System/Ticket/CustomExample.pm',
    '/Kernel/System/AsynchronousExecutor.pm',
);

# regex
my @ObjectBlacklist  = (
    'ZnunyPODParserObject'
);

# regex
my @FunctionBlacklist  = (
    '\A_',
);

# regex
my @VersionBlacklist  = (
    '6.1',
    '6.2',
    '6.3',
);

# start the magic
Run();

=head2 PrintUsage()

Parses the current framework folder.

    my $Result = PrintUsage();

=cut

sub PrintUsage {
    print <<EOF;

Generates Znuny Snippets for VisualStudioCode (VSC) Text.

Usage:
    znuny.GenerateVSCSnippets.pl [--dry-run] [--version]

Options:

    [--dry-run]   - Report only, do not create anything.
    [--version]   - Generate Snippets for given version.
    [--help]      - Show help for this command.

    znuny.GenerateVSCSnippets.pl

Process:

    1. Make sure all needed perl libs are installed (Pod::Parser, List::MoreUtils).
    2. Link this package to the wanted Framework directory.
    3. Run this script znuny.GenerateVSCSnippets.pl to create the snippets for the current version.
    4. Repeat this for other Framework versions.

EOF
    return;
}

=head2 Run()

Parses the current framework folder.

    my $Result = Run();

=cut

sub Run {

    Getopt::Long::GetOptions(
        'dry-run'   => \$DryRun,
        'version=s' => \$GetOptVersion,
        'help'      => \$Help,
    );

    if (defined $Help) {
        PrintUsage();
        exit 0;
    }

    if (defined $GetOptVersion) {
        $Version = ValidateVersion($GetOptVersion);
    }

    my $IsOnBlacklist = grep { $_ =~ m{$Version}xms } @VersionBlacklist;
    if ($IsOnBlacklist){
        Print("<red>The version $Version is blacklisted.</red>\n\n");
        exit 1;
    }

    Print("<green>Start...</green>\n\n");

    _ReadRawDataFile();
    _TidyRawDataFile();
    _GetRawData();

    if ( !$DryRun ) {
        _GenerateSnippets();
        _WriteRawDataFile();
    }

    Print("<green>Done</green>\n");

    exit 0;
}

=head2 ValidateVersion()

Validates a version-string.

    my $Version = ValidateVersion("6.4.1");

=cut

sub ValidateVersion {
    my ( $Version ) = @_;

    $Version =~ s{^(\d+\.\d+)\..+$}{$1}xms;

    return $Version;
}

=head2 Print()

Print given text with ANSIColor.

    Print("<green>Read Raw Data File...</green>\n\n");

=cut

sub Print {
    my ( $Text ) = @_;

    $Text =~ s{<(green|yellow|red)>(.*?)</\1>}{_Color($1, $2)}gsmxe;
    print STDERR $Text;
}

=head2 _Color()

Replaces colortag with ANSIColor.

    _Color("<green>Read Raw Data File...</green>\n\n");

=cut

sub _Color {
    my ( $Color, $Text ) = @_;
    return Term::ANSIColor::color($Color) . $Text . Term::ANSIColor::color('reset');
}

=head2 _ReadRawDataFile()

Get existing snippet raw data from json file.

    _ReadRawDataFile();

=cut

sub _ReadRawDataFile {
    my ( %Param ) = @_;

    $RawDataFile ||= $Home . '/src/snippets-raw-data.json';
    $SkippedRawDataFile ||= $Home . '/src/skipped-raw-data.json';
    $ContributesSnippetsDataFile ||= $Home . '/src/contributes-snippets-data.json';

    if ( -e $RawDataFile ) {

        Print("<green>Read Raw Data File...</green>\n\n");

        my $ContentSCALARRef = $MainObject->FileRead(
            Location => $RawDataFile,
        );

        my $RawData = $JSONObject->Decode(
            Data => ${$ContentSCALARRef},
        );

        %RawData = %{$RawData};
    }

    if ( -e $SkippedRawDataFile ) {

        Print("<green>Read Skipped Raw Data File...</green>\n\n");

        my $ContentSCALARRef = $MainObject->FileRead(
            Location => $SkippedRawDataFile,
        );

        my $SkippedRawData = $JSONObject->Decode(
            Data => ${$ContentSCALARRef},
        );

        %SkippedRawData = %{$SkippedRawData};
    }
}

=head2 _TidyRawDataFile()

Tidy the current raw data.

    _TidyRawDataFile();

=cut

sub _TidyRawDataFile {
    my ( %Param ) = @_;

    for my $Type (sort keys %RawData){
        for my $Name (sort keys %{$RawData{$Type}}){
            my $Data = $RawData{$Type}->{$Name};

            if (IsArrayRefWithData( $Data )){
                @{$Data} = _RemoveBlacklistedVersion(@{$Data});
            }
            elsif(IsHashRefWithData($Data)){
                if ($Data->{FrameworkVersion}){
                    @{$Data->{FrameworkVersion}} = _RemoveBlacklistedVersion(@{$Data->{FrameworkVersion}});
                }
                for my $FunctionName (sort keys %{$Data->{Functions}}){
                    for my $FunctionContent (sort keys %{$Data->{Functions}->{$FunctionName}}){
                        @{$Data->{Functions}->{$FunctionName}->{$FunctionContent}} = _RemoveBlacklistedVersion(@{$Data->{Functions}->{$FunctionName}->{$FunctionContent}});
                    }
                }
            }
        }
    }

    for my $Type (sort keys %SkippedRawData){
        for my $Name (sort keys %{$SkippedRawData{$Type}}){
            @{$SkippedRawData{$Type}->{$Name}} = _RemoveBlacklistedVersion(@{$SkippedRawData{$Type}->{$Name}});
        }
    }

}

=head2 _RemoveBlacklistedVersion()

    my @Versions = _RemoveBlacklistedVersion(@Versions);

=cut

sub _RemoveBlacklistedVersion {
    my ( @Versions ) = @_;

    my %Versions = map { $_ => 1 } @Versions;
    VERSION:
    for my $CurrentVersion (sort keys %Versions){
        my $IsOnBlacklist = grep { $_ =~ m{$CurrentVersion}xms } @VersionBlacklist;
        next VERSION if !$IsOnBlacklist;
        delete $Versions{$CurrentVersion};
    }
    @Versions = sort keys %Versions;
    return @Versions;
}


=head2 _WriteRawDataFile()

Write raw data to json file.

    my $Success = _WriteRawDataFile();

Returns:

    my $Success = 1;

=cut

sub _WriteRawDataFile {
    my ( %Param ) = @_;

    Print("\n<green>Write Raw Data File...</green>\n\n");

    my $RawDataString = $JSONObject->Encode(
        Data     => \%RawData,
        SortKeys => 1,
        Pretty   => 1,
    );

    my $RawDataFileLocation = $MainObject->FileWrite(
        Location => $RawDataFile,
        Content  => \$RawDataString,
    );

    my $SkippedRawDataString = $JSONObject->Encode(
        Data     => \%SkippedRawData,
        SortKeys => 1,
        Pretty   => 1,
    );

    my $SkippedRawDataFileLocation = $MainObject->FileWrite(
        Location => $SkippedRawDataFile,
        Content  => \$SkippedRawDataString,
    );

    my %ContributesSnippetsData = (
        "contributes" => {
            "snippets" => \@ContributesSnippetsData,
        },
    );

    my $ContributesSnippetsDataString = $JSONObject->Encode(
        Data     => \%ContributesSnippetsData,
        SortKeys => 1,
        Pretty   => 1,
    );

    my $ContributesSnippetsDataFileLocation = $MainObject->FileWrite(
        Location => $ContributesSnippetsDataFile,
        Content  => \$ContributesSnippetsDataString,
    );

    return 1;
}

=head2 _GetRawData()

Get all raw data from framework.

    _GetRawData(
        UserID => 123,
    );

=cut

sub _GetRawData {
    my ( %Param ) = @_;

    Print("<green>Get Raw Data...</green>\n\n");

    $RawData{Objects} ||= {};
    $RawData{Modules} ||= {};

    $SkippedRawData{Modules} ||= {};
    $SkippedRawData{Files} ||= {};
    $SkippedRawData{Objects} ||= {};
    $SkippedRawData{Functions} ||= {};
    $SkippedRawData{ObjectFilesMapping} ||= {};

    _GetModules(
        %RawData,
    );
    _GetObjects(
        %RawData,
    );

    return 1;
}

=head2 _GetModules()

Collects all Modules (Kernel/Modules/*).

    _GetModules(
        Modules => {},
    );

=cut

sub _GetModules {
    my ( %Param ) = @_;

    Print("<green>Get Modules...</green>\n");

    my $ModulesDir = $Home . '/Kernel/Modules/';

    # get all available Modules
    my @FoundFiles = $MainObject->DirectoryRead(
        Directory => $ModulesDir,
        Filter    => '*.pm',
        Silent    => 1,
    );

    $Param{Modules} ||= {};
    my $Modules = $Param{Modules};

    FILE:
    for my $File (@FoundFiles) {

        $File =~ s{\/\/}{\/}xms;

        Print("\n<green>Check file:</green> '$File'...\n");

        $File =~ s{$ModulesDir}{}xms;
        $File =~ s{\.pm\z}{}xms;

        if (!grep { $File =~ m{\A$_}xms } @Modules){

            Print("<yellow>File is not included in the module list..</yellow> Skipping...\n");

            $SkippedRawData{Modules}->{$File}||= [];
            my $Versions = $SkippedRawData{Modules}->{$File};

            next FILE if grep { $_ eq $Version } @{$Versions};
            push @{$Versions}, $Version;
            next FILE;
        }

        Print("  <green>Module</green>: " . $File . "\n");

        $Modules->{$File} ||= [];
        my $Versions = $Modules->{$File};
        next FILE if grep { $_ eq $Version } @{$Versions};

        push @{$Versions}, $Version;
    }

    return 1;
}

=head2 _GetObjects()

Parses the current Framework PODs to create all objects.

    _GetObjects(
        Objects => {},
    );

Returns:

    "Objects" => {
        "ActivityDialogObject" => {
            "ObjectManager"    => "my $ActivityDialogObject = $Kernel::OM->Get('Kernel::System::ProcessManagement::ActivityDialog');",
            "Package"          => "Kernel::System::ProcessManagement::ActivityDialog"
            "FrameworkVersion" => [
                "6.0",
                "6.4"
            ],
            "Functions" => {
                "ActivityDialogCompletedCheck" => {
                    "my $Completed = $ActivityDialogObject->ActivityDialogCompletedCheck(\n    ActivityDialogEntityID => $ActivityDialogEntityID,\n    Data                   => {\n        Queue         => 'Raw',\n        DynamicField1 => 'Value',\n        Subject       => 'Testsubject',\n        # ...\n    },\n);" => [
                       "6.0",
                       "6.4"
                    ]
                },
                "ActivityDialogGet" => {
                    "my $ActivityDialog = $ActivityDialogObject->ActivityDialogGet(\n    ActivityDialogEntityID => $ActivityDialogEntityID,\n    Interface              => ['AgentInterface'],   # ['AgentInterface'] or ['CustomerInterface'] or ['AgentInterface', 'CustomerInterface'] or 'all'\n    Silent                 => 1,    # 1 or 0, default 0, if set to 1, will not log errors about not matching interfaces\n);" => [
                       "6.0",
                       "6.4"
                    ]
                }
            },
        },
    }

The following snippets are created from it:

    snippets/ObjectManager/znuny.ObjectManager.ActivityDialogObject.code-snippets
    snippets/Functions/ActivityDialogObject/znuny.ActivityDialogObject.ActivityDialogCompletedCheck.code-snippets
    snippets/Functions/ActivityDialogObject/znuny.ActivityDialogObject.ActivityDialogGet.code-snippets

=cut

sub _GetObjects {
    my ( %Param ) = @_;

    Print("\n<green>Get Objects...</green>\n");

    $Param{Objects} ||= {};
    my $Objects = $Param{Objects};
    my @FoundFiles;

    my %FilesObjectMapping;
    for my $Object (sort keys %ObjectFilesMapping){
        for my $File (@{$ObjectFilesMapping{$Object}}){
            $FilesObjectMapping{$File} = $Object;
        }
    }

    # add all found files
    @Files = map {  $Home . $_ } @Files;
    @FoundFiles = ( @FoundFiles, @Files );

    DIRECTORY:
    for my $Directory (@Directories){

        # return if directory not exists
        # multi framework version support
        if (!-e $Home . $Directory){
            Print("<red>Directory not exists.</red> " . $Home . $Directory .  "\n");
            next DIRECTORY;
        };

        # get all available files
        my @DirectoryFiles = $MainObject->DirectoryRead(
            Directory => $Home . $Directory,
            Filter    => '*.pm',
            Silent    => 1,
        );
        @FoundFiles = ( @FoundFiles, @DirectoryFiles );
    }

    # uniq elements without changing the order
    @FoundFiles = uniq(@FoundFiles);

    FILE:
    for my $File (@FoundFiles) {

        Print("\n<green>Check file:</green> '$File'...\n");

        $File =~ s{\/\/}{\/}xms;

        # skip unwanted files
        if (grep { $File =~ m{$_\Z}xms  } @FileBlacklist){

            Print("<yellow>File is on the FileBlacklist.</yellow> Skipping...\n");

            # change path to relative framework
            my $SkippedFile = $File;
            $SkippedFile =~ s{($Home)}{}xms;

            $SkippedRawData{Files}->{$SkippedFile}||= [];
            my $Versions = $SkippedRawData{Files}->{$SkippedFile};

            next FILE if grep { $_ eq $Version } @{$Versions};
            push @{$Versions}, $Version;
            next FILE;
        }

        # return if file not exists
        # multi framework version support
        if (!-e $File){
            Print("<red>File not exists.</red>\n");
            next FILE;
        };

        # skip file if exists in ObjectFilesMapping
        for my $Object (sort keys %ObjectFilesMapping){
            my $Exists = grep { $_ eq $File } @{ $ObjectFilesMapping{$Object} };
            if ($Exists){
                Print("<yellow>File is used in ObjectFilesMapping.</yellow> Skipping...\n");

                my $SkippedFile = $File;
                $SkippedFile =~ s{($Home)}{}xms;

                $SkippedRawData{ObjectFilesMapping}->{$SkippedFile}||= [];
                my $Versions = $SkippedRawData{ObjectFilesMapping}->{$SkippedFile};

                next FILE if grep { $_ eq $Version } @{$Versions};
                push @{$Versions}, $Version;
                next FILE;
            }
        }

        my $ZnunyPODParserObject = bin::ZnunyPODParser->new();

        # pass needed mappings to parser object
        $ZnunyPODParserObject->{FilesObjectMapping} = \%FilesObjectMapping;
        $ZnunyPODParserObject->{CallObjectMapping}  = \%CallObjectMapping;

        $ZnunyPODParserObject->parse_from_file($File);

        ATTRIBUTE:
        for my $RequiredAttribute (qw(ObjectManager ObjectName)) {

            next ATTRIBUTE if $ZnunyPODParserObject->{$RequiredAttribute};

            Print("<red>Can't find $RequiredAttribute instruction.</red> Skipping...\n");
            Print("<red>Maybe the file should be added to ObjectFilesMapping...</red>\n");
            next FILE;
        }

        # skip unwanted files
        my $Exists = grep { $ZnunyPODParserObject->{ObjectName} =~ m{$_}xms } @ObjectBlacklist;
        if ($Exists){

            Print("<yellow>Object $ZnunyPODParserObject->{ObjectName} is on the ObjectBlacklist.</yellow> Skipping...\n");

            $SkippedRawData{Objects}->{$ZnunyPODParserObject->{ObjectName}}||= [];
            my $Versions = $SkippedRawData{Objects}->{$ZnunyPODParserObject->{ObjectName}};

            next FILE if grep { $_ eq $Version } @{$Versions};
            push @{$Versions}, $Version;
            next FILE;
        }

        my $ObjectFiles = $ObjectFilesMapping{ $ZnunyPODParserObject->{ObjectName} };
        if ( IsArrayRefWithData($ObjectFiles) ) {
            my $ObjectName = $ZnunyPODParserObject->{ObjectName};
            for my $AdditionalObjectFile ( @{$ObjectFiles} ) {
                $ZnunyPODParserObject->parse_from_file($AdditionalObjectFile);
                $ZnunyPODParserObject->{ObjectName} = $ObjectName;
            }
        }

        $Objects->{ $ZnunyPODParserObject->{ObjectName} } ||= {};

        # copy reference for more readability
        my $ObjectRawData = $Objects->{ $ZnunyPODParserObject->{ObjectName} };

        $ObjectRawData->{ObjectManager} = $ZnunyPODParserObject->{ObjectManager};
        $ObjectRawData->{Package}       = $ZnunyPODParserObject->{Package};

        $ObjectRawData->{FrameworkVersion} ||= [];

        # add current Framework version if not present yet
        if ( !grep { $_ eq $Version } @{ $ObjectRawData->{FrameworkVersion} } ) {
            push @{ $ObjectRawData->{FrameworkVersion} }, $Version;
        }

        $ObjectRawData->{Functions} ||= {};
        my @FunctionCalls;

        FUNCTION:
        for my $FunctionName ( sort keys %{ $ZnunyPODParserObject->{FunctionCalls} } ) {

            # skip internal functions
            if (grep { $FunctionName =~ m{$_}xms } @FunctionBlacklist){

                Print("<yellow>Function $FunctionName is on the FunctionBlacklist.</yellow> Skipping...\n");

                $SkippedRawData{Functions}->{$FunctionName}||= [];
                my $Versions = $SkippedRawData{Functions}->{$FunctionName};

                next FUNCTION if grep { $_ eq $Version } @{$Versions};
                push @{$Versions}, $Version;
                next FUNCTION;
            }

            push @FunctionCalls, $FunctionName;

            $ObjectRawData->{Functions}->{$FunctionName} ||= {};

            # copy reference for more readability
            my $ObjectFunction = $ObjectRawData->{Functions}->{$FunctionName};

            my $FunctionCalls = $ZnunyPODParserObject->{FunctionCalls}->{$FunctionName};

            CALL:
            for my $FunctionCall ( @{$FunctionCalls} ) {

                my $FunctionCallReplaced = $FunctionCall;

                # replace " TicketID => 123," with " TicketID => $TicketID,"
                $FunctionCallReplaced =~ s{(\s(\w+ID)\s+=>\s+)[^,]+,}{$1\$$2,}gxms;

                # replace TicketNumber parameter with var
                $FunctionCallReplaced =~ s{(\sTicketNumber\s+=>\s+)[^,]+,}{$1\$TicketNumber,}gxms;

                $ObjectFunction->{$FunctionCallReplaced} ||= [];

                # copy reference for more readability
                my $Versions = $ObjectFunction->{$FunctionCallReplaced};

                # add current Framework version if not present yet
                next CALL if grep { $_ eq $Version } @{$Versions};

                push @{$Versions}, $Version;
            }
        }

        Print("  <green>Object</green>: " . $ZnunyPODParserObject->{ObjectName} . "\n");
        for my $FunctionName ( @FunctionCalls ) {
            Print("    <green>Function</green>: " . $FunctionName . "\n");
        }
    }

    return 1;
}

=head2 _GenerateSnippets()

Write raw data to multiple snippet files.

    my $Success = _GenerateSnippets();

Returns:

    my $Success = 1;

=cut

sub _GenerateSnippets {
    my ( %Param ) = @_;

    _GenerateModuleSnippets();
    _GenerateObjectSnippets();

    return 1;
}

=head2 _GenerateModuleSnippets()

Write raw data to multiple snippet files.

    my $Success = _GenerateModuleSnippets();

Returns:

    my $Success = 1;

=cut

sub _GenerateModuleSnippets {
    my ( %Param ) = @_;

    for my $Module (sort keys %{$RawData{Modules}}){

        my %Snippet = (
            Filename    => 'znuny.Module.' . $Module . '.code-snippets',
            Trigger     => $Module,
            Content     => $Module,
            Description => join(', ',@{$RawData{Modules}->{$Module}}),
            Scope       => 'perl',
            Directory   => '/snippets/Modules/',
        );

        _WriteSnippets(%Snippet);
    }

    return 1;
}

=head2 _GenerateObjectSnippets()

Write raw data to multiple snippet files.

    my $Success = _GenerateObjectSnippets();

Returns:

    my $Success = 1;

=cut

sub _GenerateObjectSnippets {
    my ( %Param ) = @_;

    for my $Object (sort keys %{$RawData{Objects}}){

        # create ObjectManager snippets
        my %Object               = %{$RawData{Objects}->{$Object}};
        my $ObjectManagerContent = _PrepareContent($Object{ObjectManager});

        my %Snippet = (
            Filename    => 'znuny.ObjectManager.' . $Object . '.code-snippets',
            Trigger     => 'znuny.ObjectManager.' . $Object,
            Content     => $ObjectManagerContent,
            Description => join(', ',@{$Object{FrameworkVersion}}),
            Scope       => 'perl',
            Directory   => '/snippets/ObjectManager/',
        );
        _WriteSnippets(%Snippet);

        # create Function snippets
        for my $Function (sort keys %{$Object{Functions}}){

            my $Content;
            my @FrameworkVersion;
            my $Counter = 0;
            my %Function = %{$Object{Functions}->{$Function}};
            my @Versions;

            FUNCTIONCALL:
            for my $FunctionCall (sort keys %Function){
                $Counter++;

                # replace special chars
                my $FunctionContent = _PrepareContent($FunctionCall);

                $Content .= '${' . $Counter . ':' . $FunctionContent . "}\n";
                push @Versions, @{$Function{$FunctionCall}};
            }

            my %Versions = map { $_ => 1 } @Versions;
            my $Versions = join(", ", map { $_ } sort keys %Versions);

            my %Snippet = (
                Filename    => 'znuny.' . $Object . '.' . $Function . '.code-snippets',
                Trigger     => 'znuny.' . $Object . '.' . $Function,
                Content     => $Content,
                Description => $Versions,
                Scope       => 'perl',
                Directory   => '/snippets/Functions/' . $Object . '/',
            );
            _WriteSnippets(%Snippet);
        }
    }

    return 1;
}

=head2 _PrepareContent()

Escape, replace and tidy up some special chars.

    my $Content = _PrepareContent("$Function");

Returns:

    my $Content = "\$Function;

=cut

sub _PrepareContent {
    my ( $Content ) = @_;

    $Content =~ s{\$}{\\\$}g;
    $Content =~ s{\}}{\\\\\}}g;
    $Content =~ s{\n+\z}{}g;

    return $Content;
}

=head2 _WriteSnippets()

Creates snippet file.

    my $Success = _WriteSnippets(
        Filename    => 'znuny.Module.CustomerTicketSearch.code-snippets',
        Trigger     => 'CustomerTicketSearch',
        Content     => 'CustomerTicketSearch',
        Description => '6.4',
        Scope       => 'perl',
        Directory   => '/snippets/Modules/',
    );

Returns:

    my $Success = 1;

=cut

sub _WriteSnippets {
    my ( %Snippet ) = @_;

    NEEDED:
    for my $Needed ( qw(Filename Trigger Content Description Scope Directory) ) {

        next NEEDED if defined $Snippet{ $Needed };
        Print("<red>ERROR: Snippet value '$Needed' is needed for '$Snippet{Trigger}'.</red> Skipping...\n");

        return;
    }

    my $ModifiedContent = "\n";
    for my $Line ( split "\n", $Snippet{Content} ) {
        $ModifiedContent .= "            \"$Line\",\n";
    }

    my $Snippet = <<SNIPPET;
{
    "$Snippet{Trigger}": {
        "body": [$ModifiedContent        ],
        "prefix": "$Snippet{Trigger}",
        "description": "$Snippet{Description}",
        "scope": "$Snippet{Scope}"
    }
}
SNIPPET

    my $SnippetDirectory = $PackageDir . $Snippet{Directory};

    if ( !-d $SnippetDirectory ) {
        make_path $SnippetDirectory or die "Failed to create path: $SnippetDirectory";
    }

    $MainObject->FileWrite(
        Directory => $SnippetDirectory,
        Filename  => $Snippet{Filename},
        Content   => \$Snippet,
    );

    _AddContributesSnippetsData(%Snippet);

    return 1;
}

=head2 _AddContributesSnippetsData()

Add snippet data to contributes snippets list to update package.json

    my $Success = _AddContributesSnippetsData(
        Filename    => 'znuny.Module.CustomerTicketSearch.code-snippets',
        Trigger     => 'CustomerTicketSearch',
        Content     => 'CustomerTicketSearch',
        Description => '6.4',
        Scope       => 'perl',
        Directory   => '/snippets/Modules/',
    );

Returns:

    my $Success = 1;

=cut

sub _AddContributesSnippetsData {
    my ( %Snippet ) = @_;

    push @ContributesSnippetsData, {
        language => $Snippet{Scope},
        path     => '.' . $Snippet{Directory} . $Snippet{Filename},
    };
}

exit 0;
