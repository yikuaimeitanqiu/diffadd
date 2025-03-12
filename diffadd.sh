#!/usr/bin/env bash


# 脚本描述：
# 1. 对比旧的与新的文件配置，只将新的文件配置写入旧文件中
#
# 2. 针对 yaml/yml 文件的格式，会采取激进的配置追加方式
#   - 对 : 表示的键值对 可完好的适配新配置追加
#   - 对 - 表示的列表项格式数据做覆盖
#   - 对 # 表示的注释说明，不跟踪不追加到配置中
#
# 3. 其它通用类型的文件格式，使用温和地追加配置，会存在部分配置追加不上问题。
#   - .xml 受制于 元素和属性 的不确定性，以及命名的多样性，无法做匹配处理
#   - .json 的数据类型构成的复杂多样性，无法做匹配处理
#
#
# 脚本过程：
#   1. 将脚本中使用到的命令绑定来自 busybox 中的命令集合
#   2. 通过入参获取待对比的旧文件和新文件
#   3. 通过 diff -u 比较差异之处，两个处理
#       - 当只有新增加的差异，直接通过 patch 打补丁完成新配置追加
#
#       - 当存在不同差异时，判断是否为 yaml/yml 格式文件
#           - 不是 yaml/yml 文件，则从里面找到只有新增的内容，追加到旧配置文件中，会存在漏追加配置。

#           - 是 yaml/yml 文件，则在中间的临时文件中，将新旧不同处配置做替换后（将旧配置覆盖新配置，将差异外变成相同）
#               最终，通过 diff -u 得到全部只有新增加的内容，再追加到旧配置文件中。
#               - 第一次处理后，还是存在旧配置文件比新配置文件多出差异处，则再进行第二次处理：
#                   - 将旧配置不同之处，在再新生成中间临时文件，反向对原临时中间文件打补丁，做同化处理。
#                       - 再次检查做 diff -u 检查，如不存在差异正常退出，存在差异：
#                           - 只有新增加的，正常追加配置
#                           - 还是存在不同的差异，则不再进行追加配置，差异之处，属于旧配置文件独有选项。
#
#
#

# 脚本路径
DIFF_SCRIPT_PATH="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# 字体颜色
YELLOW='\033[0;33m\n'
RED='\033[0;31m'
RESET='\n\033[0m'
GREEN='\033[0;32m'

# 获取当前系统架构
ARCH="$(arch)"

# 判断系统是否为 x86_64 和 aarch64 架构
case "${ARCH}" in
    x86_64|aarch64)
        :
        ;;
    *)
        echo -e "${YELLOW}WARN: The current ${ARCH} system is not adapted, there may be problems.${RESET}"
        ;;
esac

# 检查busybox是否存在
if [ -f "${DIFF_SCRIPT_PATH}/busybox/${ARCH}/busybox" ]; then

    # patch 路径
    PATCH="${DIFF_SCRIPT_PATH}/busybox/${ARCH}/busybox patch"
    # diff 路径
    DIFF="${DIFF_SCRIPT_PATH}/busybox/${ARCH}/busybox diff"
    # mktemp 路径
    MKTEMP="${DIFF_SCRIPT_PATH}/busybox/${ARCH}/busybox mktemp"
    # sed 路径
    SED="${DIFF_SCRIPT_PATH}/busybox/${ARCH}/busybox sed"
    # grep 路径
    GREP="${DIFF_SCRIPT_PATH}/busybox/${ARCH}/busybox grep"
    # awk 路径
    AWK="${DIFF_SCRIPT_PATH}/busybox/${ARCH}/busybox awk"
    # wc 路径
    WC="${DIFF_SCRIPT_PATH}/busybox/${ARCH}/busybox wc"
    # rm 路径
    RM="${DIFF_SCRIPT_PATH}/busybox/${ARCH}/busybox rm"
    # cp 路径
    CP="${DIFF_SCRIPT_PATH}/busybox/${ARCH}/busybox cp"
    # basename 路径
    BASENAME="${DIFF_SCRIPT_PATH}/busybox/${ARCH}/busybox basename"
    # echo 路径
    ECHO="${DIFF_SCRIPT_PATH}/busybox/${ARCH}/busybox echo"

else

    # 检查diff patch 命令
    for item in diff patch ; do
        if ! command -v "${item}" 1>/dev/null; then
            ${ECHO} -e "${RED} ${item} command not found.${RESET}"
            exit 127
        fi
    done

    # 设置默认变量
    PATCH="patch"
    DIFF="diff"
    MKTEMP="mktemp"
    SED="sed"
    GREP="grep"
    AWK="awk"
    WC="wc"
    RM="rm"
    CP="cp"
    BASENAME="basename"
    ECHO="echo"

fi

# 旧配置文件，从脚本中第一个入参获取，建议写绝对路径
SOURCE_FILE="${1}"

# 新配置文件，从脚本中第二个入参获取，建议写绝对路径
NEW_FILE="${2}"

# 当入参小于二时
if [ $# -lt 2 ]; then
    ${ECHO} -e "${YELLOW}Usage: $0 <old_config_file> <new_config_file>${RESET}"
    ${ECHO} -e "${YELLOW}<old_config_file> ${GREEN}For the old configuration files to be compared, \
${RED}it is recommended to fill in the absolute path of the file.${RESET}"
    ${ECHO} -e "${YELLOW}<new_config_file> ${GREEN}For the new configuration file to be compared, \
${RED}it is recommended to fill in the absolute path of the file.${RESET}"
    exit 127
fi

# 检查新配置文件是否存在
if [ ! -f "${NEW_FILE}" ]; then
    ${ECHO} -e "${RED}Error: New configuration file '${NEW_FILE}' does not exist.${RESET}"
    exit 127
fi

# 检查旧配置文件是否存在
if [ ! -f "${SOURCE_FILE}" ]; then
    ${ECHO} -e "${RED}Error: Old configuration file '${SOURCE_FILE}' does not exist.${RESET}"
    exit 127
fi

# 获取源文件的格式后缀
EXTENSION="$( ${BASENAME} "${SOURCE_FILE}" | ${AWK} -F '.' '{print $NF}' )"

# 判断文件后缀格式
case "${EXTENSION}" in
    yaml|yml)
        FILE_TYPE='yaml'
        ;;
    *)
        FILE_TYPE='other'
        ;;
esac

# 生成补丁文件
DIFF_OUTPUT="$( ${DIFF} -u "${SOURCE_FILE}" "${NEW_FILE}")"

# 未有需要作出修改的配置退出
if [ -z "${DIFF_OUTPUT}" ]; then
    exit 0
fi

# 创建一个临时文件保存补丁内容
TEMP_PATCH_FILE="$( ${MKTEMP} )"

# 补丁内容写到临时文件中
${ECHO} "${DIFF_OUTPUT}" > "${TEMP_PATCH_FILE}"

# 检查是否存在不相同处配置
MULTIPLE_DIFF_LINE="$( ${AWK} '/^-/ && !/^---/ {print}' "${TEMP_PATCH_FILE}" | ${WC} -l )"



# 存在一处及以上的不相同处的配置
if [ "${MULTIPLE_DIFF_LINE}" -ge 1 ]; then

    # 针对yaml配置文件激进的增加新配置方式
    if [ "${FILE_TYPE}" == 'yaml' ]; then
        # 创建一个临时文件记录替换内容
        TEMP_REPLACE_FILE="$( ${MKTEMP} )"

        # 将新配置文件存放到临时转换的文件中
        ${CP} -rf "${NEW_FILE}" "${TEMP_REPLACE_FILE}"

    # 其它通用文件，采取谨慎的，只增加新配置方式
    elif [ "${FILE_TYPE}" == 'other' ]; then
        # 创建一个临时文件记录新增加的内容
        TEMP_PATCH_FILE_NEW="$( ${MKTEMP} )"

        # 生成新的对比文件，只取出第一行和第二行内容
        ${SED} -n "1,2p" "${TEMP_PATCH_FILE}" > "${TEMP_PATCH_FILE_NEW}"
    fi


    # 获取差异行号开始编号
    START_NUM="$( ${GREP} -En "^@@.*@@$" "${TEMP_PATCH_FILE}" | ${AWK} -F ':' '{print $1}' )"

    # 获取取文件中最末尾行号
    LAST_NUM="$( ${WC} -l < "${TEMP_PATCH_FILE}" )"

    # 所有行号
    ALL_NUM="${START_NUM} ${LAST_NUM}"

    # 设置空数组
    DIFF_LINE_LISTS=()

    # 将行号按数组存入
    for item in ${ALL_NUM}; do
        DIFF_LINE_LISTS+=("${item}")
    done

    # 初始化数组下标指针
    index='0'

    # 循环取第一个和第二个值，直到数组为空
    while [ "${index}" -lt "$(( ${#DIFF_LINE_LISTS[@]} - 1 ))" ]; do

        # 取出第一个值
        FIRST_VALUE="${DIFF_LINE_LISTS[${index}]}"

        # 取出的第二个值等于末尾行号时不减一
        if [ "${LAST_NUM}" -eq "${DIFF_LINE_LISTS[ $((index + 1)) ]}" ]; then
            SECOND_VALUE="${DIFF_LINE_LISTS[ $((index + 1)) ]}"
        else
            # 取出第二个值并减一
            SECOND_VALUE="$(( DIFF_LINE_LISTS[ $((index + 1)) ] - 1 ))"
        fi

        # 检查行号范围内是否存在已删除的不同之处
        DIFF_DELETE="$( ${SED} -n "${FIRST_VALUE},${SECOND_VALUE}p" "${TEMP_PATCH_FILE}" | ${GREP} -E '^\-' )"

        # 检查行号范围内是否存在增加的不同之处
        DIFF_ADD="$( ${SED} -n "${FIRST_VALUE},${SECOND_VALUE}p" "${TEMP_PATCH_FILE}" | ${GREP} -E '^\+' )"

        # 转义字符串中的特殊字符
        ESCAPE_STRING() {
            # 定义函数内部变量
            local INPUT="${1}"
            # 对输入字符串进行转义处理
            # 对 \/&[]$*.^ 特殊符号进行转义处理
            ${ECHO} "${INPUT}" | ${SED} -e 's/[\/&]/\\&/g' -e 's/[]$.*[^]/\\&/g'
        }

        # 处理yaml类型文件
        if [ "${FILE_TYPE}" == 'yaml' ]; then
            # 对比内容中只存在增加的不同之处
            if [ -n "${DIFF_DELETE}" ] && [ -n "${DIFF_ADD}" ]; then
                # 将不同处，按行读取
                ${ECHO} "${DIFF_DELETE}" | while read -r line; do

                    # 冒号 : 用于定义键值对，构建映射结构。diff -u 通过脚本可批量新增加上去
                    #
                    # 连字符 - 用于定义列表项，构建列表结构。diff -u 会将列表都作为覆盖处理
                    #   连字符定义的列表项，会存在覆盖旧配置问题，需要注意列表项设置
                    #   因为定义列表项，无参考匹配值
                    #
                    # 井号 # 用于定义注释，diff -u 不会跟踪，不需要匹配
                    #
                    # 此规则只匹配 : 键值对的内容匹配
                    old_str="$( ${SED} 's/^\(-[^:]*:\).*/\1/' <<< "${line}" | ${SED} 's/^-//1' )"

                    # 匹配对应不同的
                    new_str="$( ${GREP} -E "^\+${old_str}" <<< "${DIFF_ADD}" | ${SED} 's/^+//1' )"
                    # 删除行首的 - 
                    source_str="$( ${SED} 's/^-//1' <<< "${line}" )"

                    # 进行字符串转译
                    ESCAPED_OLD_STR="$( ESCAPE_STRING "${source_str}" )"
                    ESCAPED_NEW_STR="$( ESCAPE_STRING "${new_str}" )"

                    # 判断新旧文件可以匹配再修改
                    # 未匹配到，说明当前新旧配置本身就不同，不需要做修改。
                    if [ -n "${ESCAPED_NEW_STR}" ] && [ -n "${ESCAPED_OLD_STR}" ]; then
                        # 修改文件，注意使用分隔符
                        # 检查匹配内容中有 / 字符串时，继续判断是否使用 | ;
                        # 如还匹配到，检查 , 有没有，;
                        # 还是能匹配到，最终使用 ~ 使用分隔符
                        if ${ECHO} "${source_str}${new_str}" | ${GREP} -E '[\/|,]' 1>/dev/null; then
                            if ${ECHO} "${source_str}${new_str}" | ${GREP} -E '[|]' 1>/dev/null; then
                                if ${ECHO} "${source_str}${new_str}" | ${GREP} -E '[,]' 1>/dev/null; then
                                    ${SED} -i 's~'"${ESCAPED_NEW_STR}"'~'"${ESCAPED_OLD_STR}"'~g' "${TEMP_REPLACE_FILE}"
                                else
                                    ${SED} -i 's,'"${ESCAPED_NEW_STR}"','"${ESCAPED_OLD_STR}"',g' "${TEMP_REPLACE_FILE}"
                                fi
                            else
                                ${SED} -i 's|'"${ESCAPED_NEW_STR}"'|'"${ESCAPED_OLD_STR}"'|g' "${TEMP_REPLACE_FILE}"
                            fi
                        else
                            ${SED} -i 's/'"${ESCAPED_NEW_STR}"'/'"${ESCAPED_OLD_STR}"'/g' "${TEMP_REPLACE_FILE}"
                        fi
                    fi

                done
            fi
        fi


        # 处理其它通用类型文件
        if [ "${FILE_TYPE}" == 'other' ]; then
            # 对比内容中只存在增加的不同之处
            if [ -z "${DIFF_DELETE}" ] && [ -n "${DIFF_ADD}" ]; then
                ${SED} -n "${FIRST_VALUE},${SECOND_VALUE}p" "${TEMP_PATCH_FILE}" >> "${TEMP_PATCH_FILE_NEW}"
            fi
        fi

        # 移动数组下标指针
        index="$((index + 1))"

    done


    # 第二次处理yaml类型文件
    if [ "${FILE_TYPE}" == 'yaml' ]; then

        # 生成新补丁文件，只有新增加配置
        DIFF_NEW_OUTPUT="$( ${DIFF} -u "${SOURCE_FILE}" "${TEMP_REPLACE_FILE}")"

        # 未有需要作出修改的配置退出
        if [ -z "${DIFF_NEW_OUTPUT}" ]; then
            # 清理临时文件
            ${RM} "${TEMP_REPLACE_FILE}"
            ${RM} "${TEMP_PATCH_FILE}"
            exit 0
        fi

        # 创建一个临时文件记录替换内容
        TEMP_REPLACE_NEW_FILE="$( ${MKTEMP} )"

        # 补丁内容写到中间临时文件中
        ${ECHO} "${DIFF_NEW_OUTPUT}" > "${TEMP_REPLACE_NEW_FILE}"

        # 检查最后校验对比是否还存在不相同处配置
        # 不同之处，说明是旧配置文件自身添加的，不需要删除调整
        MULTIPLE_DIFF_REPLACE_LINE_FIRST="$( ${AWK} '/^-/ && !/^---/ {print}' "${TEMP_REPLACE_NEW_FILE}" | ${WC} -l )"


        # 存在一处及以上的不相同处的配置
        if [ "${MULTIPLE_DIFF_REPLACE_LINE_FIRST}" -ge 1 ]; then

            # 创建一个临时文件记录新增加的内容
            TEMP_PATCH_REPLACE_FILE_NEW="$( ${MKTEMP} )"

            # 生成新的对比文件，只取出第一行和第二行内容
            ${SED} -n "1,2p" "${TEMP_REPLACE_NEW_FILE}" > "${TEMP_PATCH_REPLACE_FILE_NEW}"

            # 获取差异行号开始编号
            START_NUM="$( ${GREP} -En "^@@.*@@$" "${TEMP_REPLACE_NEW_FILE}" | ${AWK} -F ':' '{print $1}' )"

            # 获取取文件中最末尾行号
            LAST_NUM="$( ${WC} -l < "${TEMP_REPLACE_NEW_FILE}" )"

            # 所有行号
            ALL_NUM="${START_NUM} ${LAST_NUM}"

            # 设置空数组
            DIFF_LINE_LISTS=()

            # 将行号按数组存入
            for item in ${ALL_NUM}; do
                DIFF_LINE_LISTS+=("${item}")
            done

            # 初始化数组下标指针
            index='0'

            # 循环取第一个和第二个值，直到数组为空
            while [ "${index}" -lt "$(( ${#DIFF_LINE_LISTS[@]} - 1 ))" ]; do

                # 取出第一个值
                FIRST_VALUE="${DIFF_LINE_LISTS[${index}]}"

                # 取出的第二个值等于末尾行号时不减一
                if [ "${LAST_NUM}" -eq "${DIFF_LINE_LISTS[ $((index + 1)) ]}" ]; then
                    SECOND_VALUE="${DIFF_LINE_LISTS[ $((index + 1)) ]}"
                else
                    # 取出第二个值并减一
                    SECOND_VALUE="$(( DIFF_LINE_LISTS[ $((index + 1)) ] - 1 ))"
                fi

                # 检查行号范围内是否存在已删除的不同之处
                DIFF_DELETE="$( ${SED} -n "${FIRST_VALUE},${SECOND_VALUE}p" "${TEMP_REPLACE_NEW_FILE}" | ${GREP} -E '^\-' )"

                # 检查行号范围内是否存在增加的不同之处
                DIFF_ADD="$( ${SED} -n "${FIRST_VALUE},${SECOND_VALUE}p" "${TEMP_REPLACE_NEW_FILE}" | ${GREP} -E '^\+' )"

                # 对比内容中只存在增加的不同之处
                if [ -n "${DIFF_DELETE}" ] && [ -z "${DIFF_ADD}" ]; then
                    ${SED} -n "${FIRST_VALUE},${SECOND_VALUE}p" "${TEMP_REPLACE_NEW_FILE}" >> "${TEMP_PATCH_REPLACE_FILE_NEW}"
                fi

                # 移动数组下标指针
                index="$((index + 1))"

            done

            # 复制对比文件到补丁文件中
            ${CP} -rf "${TEMP_PATCH_REPLACE_FILE_NEW}" "${TEMP_PATCH_FILE}"

            # 获取行号
            CONTENT_NUM="$( ${WC} -l "${TEMP_PATCH_FILE}" | ${AWK} -F ' ' '{print $1}' )"

            # 当不同的内容大于两行时，增加进去
            if [ "${CONTENT_NUM}" -gt 2 ]; then

                # 将新增行生成到新配置文件中
                ${PATCH} -Rf "${TEMP_REPLACE_FILE}" < "${TEMP_PATCH_FILE}"

            fi

            # 生成新补丁文件，再次检查是否只有新增加配置
            DIFF_NEW_OUTPUT_SECONED="$( ${DIFF} -u "${SOURCE_FILE}" "${TEMP_REPLACE_FILE}")"

            # 未有需要作出修改的配置退出
            if [ -z "${DIFF_NEW_OUTPUT_SECONED}" ]; then
                # 清理临时文件
                ${RM} "${TEMP_PATCH_FILE}"
                ${RM} "${TEMP_REPLACE_FILE}"
                ${RM} "${TEMP_REPLACE_NEW_FILE}"
                ${RM} "${TEMP_PATCH_REPLACE_FILE_NEW}"
                exit 0
            fi

            # 创建一个临时文件记录替换内容
            TEMP_REPLACE_NEW_FILE_TEST="$( ${MKTEMP} )"

            # 补丁内容写到中间临时文件中
            ${ECHO} "${DIFF_NEW_OUTPUT_SECONED}" > "${TEMP_REPLACE_NEW_FILE_TEST}"

            # 检查最后校验对比是否还存在不相同处配置
            # 不同之处，说明是旧配置文件自身添加的，不需要删除调整
            MULTIPLE_DIFF_REPLACE_LINE_SECOND="$( ${AWK} '/^-/ && !/^---/ {print}' "${TEMP_REPLACE_NEW_FILE_TEST}" | ${WC} -l )"


            # 存在一处及以上的不相同处的配置
            if [ "${MULTIPLE_DIFF_REPLACE_LINE_SECOND}" -ge 1 ]; then
                # 清理临时文件
                ${RM} "${TEMP_PATCH_FILE}"
                ${RM} "${TEMP_REPLACE_FILE}"
                ${RM} "${TEMP_REPLACE_NEW_FILE}"
                ${RM} "${TEMP_PATCH_REPLACE_FILE_NEW}"
                ${RM} "${TEMP_REPLACE_NEW_FILE_TEST}"
                exit 0
            fi

            # 替换掉打补丁的文件
            DIFF_NEW_OUTPUT="${DIFF_NEW_OUTPUT_SECONED}"

            # 清理临时文件
            ${RM} "${TEMP_PATCH_REPLACE_FILE_NEW}"
            ${RM} "${TEMP_REPLACE_NEW_FILE_TEST}"

        fi

        # 补丁内容写到临时文件中
        ${ECHO} "${DIFF_NEW_OUTPUT}" > "${TEMP_PATCH_FILE}"

        # 清理临时文件
        ${RM} "${TEMP_REPLACE_FILE}"
        ${RM} "${TEMP_REPLACE_NEW_FILE}"

    fi

    # 处理其它通用类型文件
    if [ "${FILE_TYPE}" == 'other' ]; then

        # 复制对比文件到补丁文件中
        ${CP} -rf "${TEMP_PATCH_FILE_NEW}" "${TEMP_PATCH_FILE}"

        # 清理临时文件
        ${RM} "${TEMP_PATCH_FILE_NEW}"
    fi

fi


# 获取行号
CONTENT_NUM="$( ${WC} -l "${TEMP_PATCH_FILE}" | ${AWK} -F ' ' '{print $1}' )"

# 当不同的内容大于两行时，增加进去
if [ "${CONTENT_NUM}" -gt 2 ]; then

    # 将新增行生成到新配置文件中
    ${PATCH} "${SOURCE_FILE}" < "${TEMP_PATCH_FILE}"

fi

# 清理临时文件
${RM} "${TEMP_PATCH_FILE}"


exit 0


