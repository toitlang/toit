file(GLOB TOIT_TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*_test.toit" "**/*_test.toit")

add_custom_target(update_gold)

set(NORMALIZE_GOLD ${CMAKE_CURRENT_SOURCE_DIR}/../tools/normalize_gold.sh)

foreach(file ${TOIT_TESTS})
  get_filename_component(name ${file} NAME_WE)
  set(lib_dir ".")
  set(toit_file ${CMAKE_CURRENT_SOURCE_DIR}/${file})
  file(RELATIVE_PATH relative_negative_path ${CMAKE_CURRENT_SOURCE_DIR} ${toit_file})
  get_filename_component(relative_negative_dir "${relative_negative_path}" DIRECTORY)
  set(gold_file ${CMAKE_CURRENT_SOURCE_DIR}/gold/${relative_negative_dir}/${name}.gold)
  file(RELATIVE_PATH relative ${TOIT_SDK_SOURCE_DIR} ${toit_file})
  string(REPLACE " " "__" test_name ${relative})
  add_test(
    NAME ${test_name}
    COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/run.sh $<TARGET_FILE:toitvm> ${relative} ${gold_file} ${lib_dir} ${NORMALIZE_GOLD} "${TOIT_SDK_SOURCE_DIR}" "${VM_GIT_VERSION}"
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
  )
  set_tests_properties(${test_name} PROPERTIES TIMEOUT 40)

  file(RELATIVE_PATH relative_gold ${TOIT_SDK_SOURCE_DIR} ${gold_file})
  string(REPLACE "/" "__" generate_gold ${relative_gold})
  string(REPLACE " " "__" generate_gold ${generate_gold})
  set(generate_gold "build_${generate_gold}")
  add_custom_target(${generate_gold})

  add_custom_command(
    TARGET ${generate_gold}
    COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/run.sh --update $<TARGET_FILE:toitvm> ${relative} ${gold_file} ${lib_dir} ${NORMALIZE_GOLD} "${TOIT_SDK_SOURCE_DIR}" "${VM_GIT_VERSION}"
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    DEPENDS toitc
  )
  add_dependencies(update_gold ${generate_gold})
endforeach()

include(fail.cmake)
foreach(test ${TOIT_FAILING_TESTS})
  set_tests_properties(${test} PROPERTIES WILL_FAIL TRUE)
endforeach()
