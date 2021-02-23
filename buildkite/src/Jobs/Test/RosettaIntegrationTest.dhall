let Prelude = ../../External/Prelude.dhall
let Cmd = ../../Lib/Cmds.dhall
let S = ../../Lib/SelectFiles.dhall
let Pipeline = ../../Pipeline/Dsl.dhall
let JobSpec = ../../Pipeline/JobSpec.dhall
let Command = ../../Command/Base.dhall
let OpamInit = ../../Command/OpamInit.dhall
let WithCargo = ../../Command/WithCargo.dhall
let Docker = ../../Command/Docker/Type.dhall
let Size = ../../Command/Size.dhall
in

let user = "admin"
let password = "codarules"
let db = "archiver"
in

Pipeline.build
  Pipeline.Config::
    { spec =
      JobSpec::
        { dirtyWhen =
          [ S.strictlyStart (S.contains "src/app")
          , S.strictlyStart (S.contains "src/lib")
          , S.strictly (S.contains "Makefile")
          , S.strictlyStart (S.contains "buildkite/src/Jobs/Test/RosettaIntegrationTest")
          ]
        , path = "Test"
        , name = "RosettaIntegrationTest"
        }
    , steps =
      [ Command.build
          Command.Config::
            { commands =
              OpamInit.andThenRunInDocker
              [ "USER=${user}"
              , "POSTGRES_PASSWORD=${password}"
              , "POSTGRES_USER=${user}"
              , "POSTGRES_DB=${db}"
              ]
              (Prelude.Text.concatSep " && "
                [ "bash buildkite/scripts/setup-database-for-archive-node.sh ${user} ${password} ${db}"
                , "PGPASSWORD=${password} psql -h localhost -p 5432 -U ${user} -d ${db} < src/app/rosetta/create_schema.sql"
                , "cd src/app/rosetta && ./docker-test-start.sh"
                ])
            , label = "Rosetta integration tests"
            , key = "rosetta-integration-tests"
            , target = Size.Large
            , docker = None Docker.Type
            }
      ]
    }
