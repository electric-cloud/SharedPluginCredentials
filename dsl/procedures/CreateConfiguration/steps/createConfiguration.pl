
## === createConfiguration starts ===
#
#  Copyright 2016 Electric Cloud, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

#########################
## createcfg.pl
#########################

use ElectricCommander;
use ElectricCommander::PropDB;
use JSON;

use constant {
    SUCCESS => 0,
    ERROR   => 1,
};

## get an EC object
my $ec = new ElectricCommander();

my $projName = '$[/myProject/name]';
my $configPropertySheet;
eval {
    $configPropertySheet = $ec->getPropertyValue('/myProject/ec_configPropertySheet');
    1;
} or do {
    $configPropertySheet = 'ec_plugin_cfgs';
};


my $steps = [];
my $stepsJSON = eval { $ec->getPropertyValue("/projects/$projName/procedures/CreateConfiguration/ec_stepsWithAttachedCredentials") };
if ($stepsJSON) {
    $steps = decode_json($stepsJSON);
}

eval {
    createConfigurationPropertySheet($configPropertySheet);
    1;
} or do {
    my $err = $@;
    print $err;
    rollback($configPropertySheet, $err);
    $ec->setProperty("/myJob/configError", $err);
    exit 1;
};


my $configName = '$[config]';

eval {
    my $opts = getActualParameters();

    for my $param ($ec->getFormalParameters({
        projectName => $projName,
        procedureName => 'CreateConfiguration',
    })->findnodes('//formalParameter')) {
        my $type = $param->findvalue('type') . '';
        if ($type eq 'credential') {
            my $required = $param->findvalue('required') . '';
            my $fieldName = $param->findvalue('formalParameterName') . '';
            my $credentialName = $opts->{$fieldName};

            eval {
                createAndAttachCredential($credentialName, $configName, $configPropertySheet, $steps);
                1;
            } or do {
                my $err = $@;
                if ($required) {
                    die $err;
                }
                else {
                    print "Failed to create credential $credentialName: $err\n";
                }
            };
        }

    }
    1;
} or do {
    my $err = $@;
    print $err;
    rollback($configPropertySheet, $err);
    $ec->setProperty("/myJob/configError", $err);
    exit 1;
};

sub createAndAttachCredential {
    my ($credName, $configName, $configPropertySheet, $steps) = @_;

    my $xpath = $ec->getFullCredential($credName);
    my $errors = $ec->checkAllErrors($xpath);

    my $clientID = $xpath->findvalue("//userName");
    my $clientSecret = $xpath->findvalue("//password");

    my $projName = '$[/myProject/projectName]';

    my $credObjectName = $credName eq 'credential' ? $configName : "${configName}_${credName}";
    # die $credObjectName;
    # Create credential
    $ec->deleteCredential($projName, $credObjectName);
    $xpath = $ec->createCredential($projName, $credObjectName, $clientID, $clientSecret);
    $errors .= $ec->checkAllErrors($xpath);

    # Give config the credential's real name
    my $configPath = "/projects/$projName/$configPropertySheet/$configName/$credName";
    $xpath = $ec->setProperty($configPath, $credObjectName);
    $errors .= $ec->checkAllErrors($xpath);

    # Give job launcher full permissions on the credential
    my $user = '$[/myJob/launchedByUser]';
    $xpath = $ec->createAclEntry("user", $user, {
        projectName => $projName,
        credentialName => $credObjectName,
        readPrivilege => 'allow',
        modifyPrivilege => 'allow',
        executePrivilege => 'allow',
        changePermissionsPrivilege => 'allow'
    });
    $errors .= $ec->checkAllErrors($xpath);
    # Attach credential to steps that will need it
    for my $step( @$steps ) {
        print "Attaching credential to procedure " . $step->{procedureName} . " at step " . $step->{stepName} . "\n";
        my $apath = $ec->attachCredential($projName, $credObjectName,
                                        {procedureName => $step->{procedureName},
                                         stepName => $step->{stepName}});
        $errors .= $ec->checkAllErrors($apath);
    }

    if ("$errors" ne "") {
        # Cleanup the partially created configuration we just created
        $ec->deleteProperty($configPath);
        $ec->deleteCredential($projName, $credObjectName);
        my $errMsg = "Error creating configuration credential: " . $errors;
        $ec->setProperty("/myJob/configError", $errMsg);
        die $errMsg;
    }
}

sub rollback {
    my ($configPropertySheet, $error) = @_;

    if ($error !~ /already exists/) {
        my $configName = '$[config]';
        $ec->deleteProperty("/myProject/$configPropertySheet/$configName");
    }
}

sub getActualParameters {
    my $x       = $ec->getJobDetails($ENV{COMMANDER_JOBID});
    my $nodeset = $x->find('//actualParameter');
    my $opts;

    foreach my $node ($nodeset->get_nodelist) {
        my $parm = $node->findvalue('actualParameterName');
        my $val  = $node->findvalue('value');
        $opts->{$parm} = "$val";
    }
    return $opts;
}

sub createConfigurationPropertySheet {
    my ($configPropertySheet) = @_;

    my $opts = getActualParameters();
    ## load option list from procedure parameters
    my $ec = ElectricCommander->new;
    $ec->abortOnError(0);

    use Data::Dumper;

    for my $key (keys %$opts) {
        if ($key =~ /__shared/) {
            # Need to attach the actual credential to the job step
            my $cred_path = $opts->{$key};
            my @parts = split /\// => $cred_path;

            my $projName = $parts[2];
            my $credObjectName = $parts[4];

            for my $step( @$steps ) {
                print "Attaching credential  to procedure " . $step->{procedureName} . " at step " . $step->{stepName} . "\n";
                my $apath = $ec->attachCredential('@PLUGIN_NAME@', $cred_path,
                {
                    procedureName => $step->{procedureName},
                    stepName => $step->{stepName},
                 });
                $errors .= $ec->checkAllErrors($apath);
            }
        }
    }


    my $x       = $ec->getJobDetails($ENV{COMMANDER_JOBID});
    my $nodeset = $x->find('//actualParameter');


    if (!defined $opts->{config} || "$opts->{config}" eq "") {
        die "config parameter must exist and be non-blank\n";
    }

    # check to see if a config with this name already exists before we do anything else
    my $xpath    = $ec->getProperty("/myProject/$configPropertySheet/$opts->{config}");
    my $property = $xpath->findvalue("//response/property/propertyName");

    if (defined $property && "$property" ne "") {
        my $errMsg = "A configuration named '$opts->{config}' already exists.";
        $ec->setProperty("/myJob/configError", $errMsg);
        die $errMsg;
    }

    my $cfg = new ElectricCommander::PropDB($ec, "/myProject/$configPropertySheet");

    # add all the options as properties
    foreach my $key (keys %{$opts}) {
        if ("$key" eq "config") {
            next;
        }
        $cfg->setCol("$opts->{config}", "$key", "$opts->{$key}");

    }
}
## === createConfiguration ends, checksum: b9c4ad2aeb2b3997dfbec1b845c4d7b4 ===
# user-defined code can be placed below this line
# Do not edit the code above the line as it will be updated upon plugin upgrade
