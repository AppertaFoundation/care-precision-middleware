

            # # Are we doing a filtered return (search?)
            # my $filtered_search = do {
            #     if (defined $payload && $payload->{filter}) { 1 }
            #     else { 0 }
            # };

            # # A place to build the returned object
            # my $search_result = [];

            # # IF we are not doing a filtered search simply return everything
            # if ($filtered_search == 0) {
            #     push @{$search_result},@{$global->{patient_db}->{entry}};
            # }
            # elsif (
            #     $payload->{filter}->{system}
            #     &&
            #     $payload->{filter}->{target}
            # ) {
            #     # We can have upto three options in the search
            #     # Lets validate them more


            #     foreach my $patient ( @{ $global->{patient_db}->{entry} } ) {
            #         # Do we have a path?
            #         if (@{$search_path} > 0) {
            #             # Yes we do .. let us start there
            #             try {
            #                 $patient_info = $patient->
            #             }
                        
            #         }                    
            #     }
            # }
