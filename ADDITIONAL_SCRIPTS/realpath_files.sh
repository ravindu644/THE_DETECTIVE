while IFS= read -r lib; do
    find . -type f -name "$lib" -exec realpath {} \;
done < /home/ravindu644/Desktop/missing_hal.txt | sort -u
