{application,sniffle,
             [{description,"Central cloud management server."},
              {vsn,"0.2.0"},
              {registered,[]},
              {applications,[kernel,erllibcloudapi,redo,backyard,sasl,alog,
                             uuid,libsnarl,libchunter,statsderl,vmstats,
                             stdlib]},
              {mod,{sniffle_app,[]}},
              {env,[]},
              {modules,[sniffle_app,sniffle_host_srv,sniffle_host_sup,
                        sniffle_impl,sniffle_impl_bark,sniffle_impl_chunter,
                        sniffle_impl_cloudapi,sniffle_server,sniffle_sup]}]}.