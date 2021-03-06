#!/bin/sh

Usage()
{
    echo "Usage: ./build-xref.sh <sourceroot> <objdir> <mozconfig> <xrefscripts> <dbdir> <dbname> <wwwdir> <treename>"
}

if [ -z "$1" ]; then
    Usage
    exit
fi
SOURCEROOT=$1

if [ -z "$2" ]; then
    Usage
    exit
fi
OBJDIR=$2

if [ -z "$3" ]; then
    Usage
    exit
fi
MOZCONFIG=$3

if [ -z "$4" ]; then
    Usage
    exit
fi
DXRSCRIPTS=$4

if [ -z "$5" ]; then
    Usage
    exit
fi
DBROOT=$5

if [ -z "$6" ]; then
    Usage
    exit
fi
DBNAME=$6

if [ -z "$7" ]; then
    Usage
    exit
fi
WWWDIR=$7

if [ -z "$8" ]; then
    Usage
    exit
fi
TREENAME=$8

# backup current data while we build new
if [ -d ${WWWDIR}/${TREENAME}-current ]
then
    # See if last build/index was successful
    if [ -e ${WWWDIR}/${TREENAME}-current/.dxr_xref/.success ]
    then 
      # Leave the existing -old index in place and try again (failed build)
      rm -fr ${WWWDIR}/${TREENAME}-current	
    else 
      # Backup the existing so the web app still works while we build the new one
      rm -fr ${WWWDIR}/${TREENAME}-old
      mv ${WWWDIR}/${TREENAME}-current ${WWWDIR}/${TREENAME}-old
      rm -f ${WWWDIR}/${TREENAME} # symlink to -current
      ln -s ${WWWDIR}/${TREENAME}-old ${WWWDIR}/${TREENAME}
    fi
fi

mkdir ${WWWDIR}/${TREENAME}-current

# create dir to hold db if not present
if [ ! -d ${DBROOT} ]; then mkdir ${DBROOT}; fi

cd ${DBROOT}

# fix-up NSS, since it will copy (and lose links) from dist/include/public/nss to dist/include/nss
echo "Fix NSS symlinks..."
# Figure out where dist is (assume mozilla-central objdir/dist)
DISTPARENT=${OBJDIR}
if [ -d ${OBJDIR}/mozilla/dist ]
then
    # comm-central
    DISTPARENT=${OBJDIR}/mozilla
fi
rm -f ${DISTPARENT}/dist/include/nss/*.h
ln -s ${DISTPARENT}/dist/public/nss/*.h ${DISTPARENT}/dist/include/nss

# merge and de-dupe sql scripts, putting inserts first, feed into sqlite
echo "Post-process all C++ .sql and create db..."
find ${OBJDIR} -name '*.sql' -exec cat {} \; > ${DBROOT}/all.sql
awk '!($0 in a) {a[$0];print}' ${DBROOT}/all.sql > ${DBROOT}/all-uniq.sql
rm ${DBROOT}/all.sql
cat ${DBROOT}/all-uniq.sql | ${DXRSCRIPTS}/fix_paths.pl ${SOURCEROOT} ${OBJDIR} > ${DBROOT}/all-uniq-fixed-paths.sql
rm ${DBROOT}/all-uniq.sql
grep "^insert" ${DBROOT}/all-uniq-fixed-paths.sql > ${DBROOT}/cpp-insert.sql
grep -v "^insert" ${DBROOT}/all-uniq-fixed-paths.sql > ${DBROOT}/cpp-update.sql
rm ${DBROOT}/all-uniq-fixed-paths.sql

echo 'PRAGMA journal_mode=off; PRAGMA locking_mode=EXCLUSIVE; BEGIN TRANSACTION;' > ${DBROOT}/all-cpp.sql
cat ${DXRSCRIPTS}/dxr-schema.sql >> ${DBROOT}/all-cpp.sql
echo 'COMMIT; PRAGMA locking_mode=NORMAL;' >> ${DBROOT}/all-cpp.sql
echo 'PRAGMA journal_mode=off; PRAGMA locking_mode=EXCLUSIVE; BEGIN TRANSACTION;' >> ${DBROOT}/all-cpp.sql
cat ${DBROOT}/cpp-insert.sql >> ${DBROOT}/all-cpp.sql
echo 'COMMIT; PRAGMA locking_mode=NORMAL;' >> ${DBROOT}/all-cpp.sql
echo 'PRAGMA journal_mode=off; PRAGMA locking_mode=EXCLUSIVE; BEGIN TRANSACTION;' >> ${DBROOT}/all-cpp.sql
cat ${DXRSCRIPTS}/dxr-indices.sql >> ${DBROOT}/all-cpp.sql
echo 'COMMIT; PRAGMA locking_mode=NORMAL;' >> ${DBROOT}/all-cpp.sql
cat ${DBROOT}/cpp-update.sql >> ${DBROOT}/all-cpp.sql
echo 'COMMIT; PRAGMA locking_mode=NORMAL;' >> ${DBROOT}/all-cpp.sql

sqlite3 ${DBROOT}/${DBNAME} < ${DBROOT}/all-cpp.sql > ${DBROOT}/error-cpp.log 2>&1
rm ${DBROOT}/cpp-insert.sql
rm ${DBROOT}/cpp-update.sql
# XXX: leaving this file for debugging
#rm ${DBROOT}/all-cpp.sql
echo "DB built."

echo "Process IDL .xref info into SQL..."
find ${OBJDIR} -name '*.xref' -exec cat {} \; | ${DXRSCRIPTS}/process_xref.pl ${SOURCEROOT} > ${DBROOT}/idl.sql

echo "Insert idl sql into db, then update existing type info with idl data..."
echo 'PRAGMA count_changes=off; PRAGMA synchronous=off; PRAGMA journal_mode=off; PRAGMA locking_mode=EXCLUSIVE; PRAGMA cache_size=4000; BEGIN TRANSACTION;' > ${DBROOT}/all-idl.sql
cat ${DBROOT}/idl.sql >> ${DBROOT}/all-idl.sql
echo 'COMMIT; PRAGMA locking_mode=NORMAL; ' >> ${DBROOT}/all-idl.sql

sqlite3 ${DBROOT}/${DBNAME} < ${DBROOT}/all-idl.sql > ${DBROOT}/error-idl.log 2>&1
# XXX: leaving this file for debugging
#rm ${DBROOT}/all-idl.sql

# create SQL for all .macros files 
echo "Process .macros info into SQL..."
find ${OBJDIR} -name '*.macros' -exec cat {} \; > ${DBROOT}/macros
awk '!($0 in a) {a[$0];print}' ${DBROOT}/macros > ${DBROOT}/macros-uniq
rm ${DBROOT}/macros
cat ${DBROOT}/macros-uniq | ${DXRSCRIPTS}/process_macros.pl > ${DBROOT}/macros-uniq-processed
rm ${DBROOT}/macros-uniq
echo 'PRAGMA journal_mode=off; PRAGMA locking_mode=EXCLUSIVE; PRAGMA coung_changes=off; BEGIN TRANSACTION;' > ${DBROOT}/all-macros.sql
cat ${DBROOT}/macros-uniq-processed >> ${DBROOT}/all-macros.sql
echo 'COMMIT; PRAGMA locking_mode=NORMAL;' >> ${DBROOT}/all-macros.sql
sqlite3 ${DBROOT}/${DBNAME} < ${DBROOT}/all-macros.sql > ${DBROOT}/error-macros.log 2>&1
rm ${DBROOT}/macros-uniq-processed
# XXX: leaving this file for debugging
#rm ${DBROOT}/all-macros.sql

# Extract gcc warnings
echo "Process GCC warnings into SQL..."
echo 'PRAGMA journal_mode=off; PRAGMA locking_mode=EXCLUSIVE; PRAGMA coung_changes=off; BEGIN TRANSACTION;' > ${DBROOT}/warnings.sql
python ${DXRSCRIPTS}/warning-parser.py ${SOURCEROOT} ${OBJDIR} ${DBROOT}/build-log.txt >> ${DBROOT}/warnings.sql
echo 'COMMIT; PRAGMA locking_mode=NORMAL;' >> ${DBROOT}/warnings.sql
sqlite3 ${DBROOT}/${DBNAME} < ${DBROOT}/warnings.sql > ${DBROOT}/warnings-error.log 2>&1

# create callgraph
echo "Process callgraph .sql..."
(cat ${DXRSCRIPTS}/callgraph/schema.sql
echo 'BEGIN TRANSACTION;'
find ${OBJDIR} -name '*.cg.sql' | xargs cat
cat ${DXRSCRIPTS}/callgraph/indices.sql
echo 'COMMIT;') > ${DBROOT}/callgraph.sql
sqlite3 ${DBROOT}/${DBNAME} < ${DBROOT}/callgraph.sql > ${DBROOT}/callgraph.log 2>&1

# Defrag db
sqlite3 ${DBNAME} "VACUUM;"

# Everything worked, log success
touch ${DBROOT}/.success

echo "Done - DB created at ${DBROOT}/${DBNAME}"
