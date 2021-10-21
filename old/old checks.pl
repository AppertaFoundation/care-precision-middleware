
                # # Step 1.1 - json.header
                # my $test_header = do {
                #     my $test_result = 1;
                #     my $header;

                #     # Validate the header is present
                #     if (
                #         defined $spec->{input}->{header}
                #         && ref($spec->{input}->{header}) eq 'HASH'
                #     )   {
                #         $header = $spec->{input}->{header};
                #     }
                #     else {
                #         $test_result = 0;
                #     }

                #     # Validate all fields are what we expect and present
                #     if (
                #         $test_result != 1
                #         || !defined $header->{healthcare_facility}
                #         || ref($header->{healthcare_facility})
                #         || !defined $header->{composer}
                #         || ref($header->{composer}) ne 'HASH'
                #         || !defined $header->{composer}->{name}
                #         || ref($header->{composer}->{name})
                #         || !defined $header->{composer}->{id}
                #         || ref($header->{composer}->{id}) ne 'HASH'
                #         || !defined $header->{composer}->{id}->{type}
                #         || ref($header->{composer}->{id}->{type})
                #         || !defined $header->{composer}->{id}->{id}
                #         || ref($header->{composer}->{id}->{id})
                #         || !defined $header->{composer}->{id}->{namespace}
                #         || ref($header->{composer}->{id}->{namespaced})
                #     )
                #     { 
                #         $return->{error_header} = "Failed validation json block 'header'";
                #         $return->{error}++;
                #         $test_result = 0; 
                #     }


                #     # Return the test result
                #     $test_result
                # };

                # # Step 1.2 - json.situation
                # my $test_situation   = do {
                #     # Inherit the previous test result
                #     my $test_result = 1;
                #     my $object;

                #     # Validate the header is present
                #     if (
                #         defined $spec->{input}->{situation}
                #         && ref($spec->{input}->{situation}) eq 'HASH'
                #     )   {
                #         $object = $spec->{input}->{situation};
                #     }
                #     else {
                #         $test_result = 0;
                #     }

                #     # Validate all fields are what we expect and present
                #     if (
                #         $test_result != 1
                #         || !defined $object->{uuid}
                #         || ref($object->{uuid})
                #         || !defined $object->{notes}
                #         || ref($object->{notes})
                #         || !defined $object->{soft_signs}
                #         || ref($object->{soft_signs}) ne 'ARRAY'
                #     )
                #     { 
                #         $return->{error_situation} = "Failed validation json block 'situation'";
                #         $return->{error} = 1;
                #         $test_result = 0;
                #     }

                #     # Return the test result
                #     $test_result
                # };

                # # Step 1.3 - json.background
                # my $test_background   = do {
                #     # Inherit the previous test result
                #     my $test_result = 1;
                #     my $object;

                #     # Validate the header is present
                #     if (
                #         defined $spec->{input}->{background}
                #         && ref($spec->{input}->{background}) eq 'HASH'
                #     )   {
                #         $object = $spec->{input}->{background};
                #     }
                #     else {
                #         $return->{error_background} = "Failed validation json block 'background'";
                #         $return->{error} = 1;
                #         $test_result = 0;
                #     }

                #     # Validate all fields are what we expect and present
                #     if (
                #         $test_result != 1
                #     )
                #     { $test_result = 0; }

                #     # Return the test result
                #     $test_result
                # };

                # # Step 1.4 - json.denwis
                # my $test_denwis   = do {
                #     # Inherit the previous test result
                #     my $test_result = 1;

                #     if ($test_result == 1) { 
                #         my $object;

                #         # Validate the header is present
                #         if (
                #             defined $spec->{input}->{denwis}
                #         )   {
                #             $object = $spec->{input}->{denwis};
                #         }
                #         else {
                #             $test_result = 1;
                #         }

                #         # Validate all fields are what we expect and present
                #         # Each element in the denwis hash should be an array or a hash
                #         foreach my $denwis_key (keys %{$object}) {
                #             # There is only three types this can be,
                #             # a string/scalar a hash or an arrayofhashes
                #             my $type = ref($object->{$denwis_key});
                #             if (!$type) { $type = 'STRING' }
                #             elsif ($type eq 'ARRAY') { $type = 'AOH' }
                #             else { $type = 'HASH' }

                #             my $valid_design = 0;

                #             if ($type eq 'STRING')  {
                #                 #say "[$type] $denwis_key = ".$object->{$denwis_key};
                #                 $valid_design = 1;
                #             }
                #             elsif ($type eq 'HASH') {
                #                 my $valid_design_subtest = 0;
                #                 my @info;
                #                 foreach my $subkey (keys %{$object->{$denwis_key}}) {
                #                     push @info,join(':',$subkey,$object->{$denwis_key}->{$subkey});
                #                     if (ref($object->{$denwis_key}->{$subkey})) { $valid_design_subtest++ }
                #                 }
                #                 my $infoblock = join(',',@info);
                #                 #say "[$type] $denwis_key = [$infoblock]";
                #                 # if valid design subtest was >0 there was a problem
                #                 warn $valid_design_subtest;
                #                 $valid_design = $valid_design_subtest==0 ? 0 : 1;
                #             }
                #             else {
                #                 my $valid_design_subtest = 0;
                #                 my $element_count = scalar(@{$object->{$denwis_key}});
                #                 #say "[$type] $denwis_key = Records in set: $element_count";
                #                 foreach my $subobject (@{$object->{$denwis_key}}) {
                #                     if (keys %{$subobject} != 3) {
                #                         $valid_design_subtest++;
                #                     }
                #                 }
                #                 $valid_design = $valid_design_subtest==0 ? 0 : 1;
                #             }
                #             $test_result = $valid_design;
                #         }

                #     }

                #     # Return the test result
                #     $test_result
                # };

                # # Step 1.5 - json.sepsis
                # my $test_sepsis   = do {
                #     # Inherit the previous test result
                #     my $test_result = 1;

                #     if ($test_result == 1) { 
                #         my $object;

                #         # Validate the header is present
                #         if (
                #             defined $spec->{input}->{sepsis}
                #         )   {
                #             $object = $spec->{input}->{sepsis};
                #         }
                #         else {
                #             $test_result = 1;
                #         }

                #         # Validate all fields are what we expect and present
                #         # Each element in the denwis hash should be an array or a hash
                #         foreach my $sepsis_key (keys %{$object}) {
                #             # There is only three types this can be,
                #             # a string/scalar a hash or an arrayofhashes
                #             my $type = ref($object->{$sepsis_key});
                #             if (!$type) { $type = 'STRING' }
                #             elsif ($type eq 'ARRAY') { $type = 'AOH' }
                #             else { $type = 'HASH' }

                #             my $valid_design = 0;

                #             if ($type eq 'STRING')  {
                #                 #say "[$type] $denwis_key = ".$object->{$denwis_key};
                #                 $valid_design = 1;
                #             }
                #             elsif ($type eq 'HASH') {
                #                 my $valid_design_subtest = 0;
                #                 my @info;
                #                 foreach my $subkey (keys %{$object->{$sepsis_key}}) {
                #                     push @info,join(':',$subkey,$object->{$sepsis_key}->{$subkey});
                #                     if (ref($object->{$sepsis_key}->{$subkey})) { $valid_design_subtest++ }
                #                 }
                #                 my $infoblock = join(',',@info);
                #                 #say "[$type] $sepsis_key = [$infoblock]";
                #                 # if valid design subtest was >0 there was a problem
                #                 $valid_design = $valid_design_subtest==0 ? 0 : 1;
                #             }
                #             else {
                #                 my $valid_design_subtest = 0;
                #                 my $element_count = scalar(@{$object->{$sepsis_key}});
                #                 say "[$type] $sepsis_key = Records in set: $element_count";
                #                 foreach my $subobject (@{$object->{$sepsis_key}}) {
                #                     if (keys %{$subobject} != 3) {
                #                         $valid_design_subtest++;
                #                     }
                #                 }
                #                 $valid_design = $valid_design_subtest==0 ? 0 : 1;
                #             }
                #             $test_result = $valid_design;
                #         }

                #     }

                #     # Return the test result
                #     $test_result
                # };

                # # Step 1.6 - json.news2
                # my $test_news2   = do {
                #     # Inherit the previous test result
                #     my $test_result = 1;

                #     if ($test_result == 1) { 
                #         my $object;

                #         # Validate the header is present
                #         if (
                #             defined $spec->{input}->{sepsis}
                #         )   {
                #             $object = $spec->{input}->{sepsis};
                #         }
                #         else {
                #             $test_result = 1;
                #         }

                #         if ($test_result == 1) {
                #             # Validate all fields are what we expect and present
                #             # Each element in the denwis hash should be an array or a hash
                #             foreach my $sepsis_key (keys %{$object}) {
                #                 # There is only three types this can be,
                #                 # a string/scalar a hash or an arrayofhashes
                #                 my $type = ref($object->{$sepsis_key});
                #                 if (!$type) { $type = 'STRING' }
                #                 elsif ($type eq 'ARRAY') { $type = 'AOH' }
                #                 else { $type = 'HASH' }

                #                 my $valid_design = 0;

                #                 if ($type eq 'STRING')  {
                #                     #say "[$type] $denwis_key = ".$object->{$denwis_key};
                #                     $valid_design = 1;
                #                 }
                #                 elsif ($type eq 'HASH') {
                #                     my $valid_design_subtest = 0;
                #                     my @info;
                #                     foreach my $subkey (keys %{$object->{$sepsis_key}}) {
                #                         push @info,join(':',$subkey,$object->{$sepsis_key}->{$subkey});
                #                         if (ref($object->{$sepsis_key}->{$subkey})) { $valid_design_subtest++ }
                #                     }
                #                     my $infoblock = join(',',@info);
                #                     #say "[$type] $sepsis_key = [$infoblock]";
                #                     # if valid design subtest was >0 there was a problem
                #                     $valid_design = $valid_design_subtest==0 ? 0 : 1;
                #                 }
                #                 else {
                #                     my $valid_design_subtest = 0;
                #                     my $element_count = scalar(@{$object->{$sepsis_key}});
                #                     say "[$type] $sepsis_key = Records in set: $element_count";
                #                     foreach my $subobject (@{$object->{$sepsis_key}}) {
                #                         if (keys %{$subobject} != 3) {
                #                             $valid_design_subtest++;
                #                         }
                #                     }
                #                     $valid_design = $valid_design_subtest==0 ? 0 : 1;
                #                 }
                #             }
                #             $test_result = $valid_design;
                #         }

                #     }

                #     # Return the test result
                #     $test_result
                # };