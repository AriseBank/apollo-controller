test_template() {
  # Import a template which only triggers on create
  deps/import-busybox --alias template-test --template create
  mercury init template-test template

  # Confirm that template application is delayed to first start
  ! mercury file pull template/template -

  # Validate that the template is applied
  mercury start template
  mercury file pull template/template - | grep "^name: template$"

  # Confirm it's not applied on copies
  mercury copy template template1
  mercury file pull template1/template - | grep "^name: template$"

  # Cleanup
  mercury image delete template-test
  mercury delete template template1 --force


  # Import a template which only triggers on copy
  deps/import-busybox --alias template-test --template copy
  mercury launch template-test template

  # Confirm that the template doesn't trigger on create
  ! mercury file pull template/template -

  # Copy the container
  mercury copy template template1

  # Confirm that template application is delayed to first start
  ! mercury file pull template1/template -

  # Validate that the template is applied
  mercury start template1
  mercury file pull template1/template - | grep "^name: template1$"

  # Cleanup
  mercury image delete template-test
  mercury delete template template1 --force


  # Import a template which only triggers on start
  deps/import-busybox --alias template-test --template start
  mercury launch template-test template

  # Validate that the template is applied
  mercury file pull template/template - | grep "^name: template$"
  mercury file pull template/template - | grep "^user.foo: _unset_$"

  # Confirm it's re-run at every start
  mercury config set template user.foo bar
  mercury restart template --force
  mercury file pull template/template - | grep "^user.foo: bar$"

  # Cleanup
  mercury image delete template-test
  mercury delete template --force


  # Import a template which triggers on both create and copy
  deps/import-busybox --alias template-test --template create,copy
  mercury init template-test template

  # Confirm that template application is delayed to first start
  ! mercury file pull template/template -

  # Validate that the template is applied
  mercury start template
  mercury file pull template/template - | grep "^name: template$"

  # Confirm it's also applied on copies
  mercury copy template template1
  mercury start template1
  mercury file pull template1/template - | grep "^name: template1$"
  mercury file pull template1/template - | grep "^user.foo: _unset_$"

  # But doesn't change on restart
  mercury config set template1 user.foo bar
  mercury restart template1 --force
  mercury file pull template1/template - | grep "^user.foo: _unset_$"

  # Cleanup
  mercury image delete template-test
  mercury delete template template1 --force
}
