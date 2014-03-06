# Description

Place for StackForge-migration related things

## Scripts

### `compare.rb`

```
$ ./compare.rb --help
usage: compare.rb [options] <YAML_FILE>
    -n, --name <COOKBOOK>     Name of StackForge cookbook (can be shortened)
    -d, --diff                Show unified diff for attributes files
    -h, --hash-diff           Show data-structure diff between attribute hashes
    -a, --all                 Diff ALL cookbook-openstack-common attrs as well
    -s, --sources <FILE>      Path to SOURCES file
        --no-color, --no-colour
                              Don't paint your rainbows at me
        --help                This useless garbage
```

Reads YAML file and determines which upstream attributes may have changed. This
is done by fetching the latest attributes file from Github master branch for
the cookbook and parsing it.  This also has the ability to show unified diff(1)
output between the newest attributes file and the one from which the YAML file
was generated (as referenced in the `SOURCES` file in the `./attr_maps/yaml/`
directory).

Example:
```
$ ./compare.rb ../attr_maps/yaml/ceilometer.yml
openstack.db.metering.db_name is missing!
openstack.metering.db.username is missing!
openstack.metering.service_tenant_name: nil (NilClass) => service (String)
openstack.metering.service_user: nil (NilClass) => ceilometer (String)
openstack.endpoints.metering-api.path: /v1 (String) => '' (String)
openstack.metering.debug: nil (NilClass) => false (String)
```

