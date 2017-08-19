# APOLLO Backup Strategies

To backup a APOLLO instance different strategies are available.

## Full backup
This requires that the whole `/var/lib/apollo` folder will be backuped up.
Additionally, it is necessary to backup all storage pools as well.

In order to restore the APOLLO instance the old `/var/lib/apollo` folder needs to be
removed and replaced with the `/var/lib/apollo` snapshot. All storage pools
need to be restored as well.

## Secondary APOLLO
This requires a second APOLLO instance to be setup and reachable from the APOLLO
instance that is to be backed up. Then, all containers can be copied to the
secondary APOLLO instance for backup.

## Container backup and restore
Additionally, APOLLO maintains a `backup.yaml` file in each container's storage
volume. This file contains all necessary information to recover a given
container, such as container configuration, attached devices and storage.
This file can be processed by the `apollo import` command.

Running 

```
apollo import <container-name>
```

will restore the specified container from its `backup.yaml` file.  This
recovery mechanism is mostly meant for emergency recoveries and will try to
re-create container and storage database entries from a backup of the storage
pool configuration.

Note that the corresponding storage volume for the container must exist and be
accessible before the container can be imported.  For example, if the
container's storage volume got unmounted the user is required to remount it
manually.

If any matching database entry for resources declared in `backup.yaml` is found
during import, the command will refuse to restore the container.  This can be
overridden running 

```
apollo import --force <container-name>
```

which causes APOLLO to delete and replace any currently existing db entries.
