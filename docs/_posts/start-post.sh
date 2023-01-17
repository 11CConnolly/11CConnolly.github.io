#!/usr/bin/env bash

# Title is $1
title=$1
# Get current time in YYYY-MM-DD Format
currentDate=`date`
day=`date +"%Y-%m-%d-"`
# Append this date to the titl
filename=$day$title".md"

touch $filename
echo -e "---\nlayout:post\ntitle: $title\ndate: $currentDate\ncategories: [[CATEGORIES]]\n---" >> $filename

