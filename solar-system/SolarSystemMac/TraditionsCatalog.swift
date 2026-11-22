import Foundation

struct Tradition: Identifiable {
    let id = UUID()
    let culture: String
    let name: String
    let detail: String
}

let traditionsByEvent: [String: [Tradition]] = [

    "Winter Solstice": [
        Tradition(
            culture: "Norse / Germanic",
            name: "Yule",
            detail: "A twelve-night midwinter feast honoring the sun's rebirth. A massive oak log was burned through the night; its embers were kept to kindle the following year's fire. Evergreens, holly, and mistletoe were brought indoors as symbols of life persisting through darkness. The wild hunt was said to ride the solstice skies."
        ),
        Tradition(
            culture: "Iran / Central Asia",
            name: "Shab-e Yalda",
            detail: "\"Night of Birth\" — Zoroastrian in origin, celebrating the sun-god Mithra. Families stay awake through the year's longest night sharing pomegranates (seeds as metaphors for hope) and watermelon, reading aloud from Hafez and Rumi until dawn. Yalda has been observed continuously for over 2,000 years."
        ),
        Tradition(
            culture: "China / East Asia",
            name: "Dongzhi",
            detail: "One of China's oldest observances; the Emperor performed rites at the Temple of Heaven at solstice dawn. Families reunite to eat tangyuan — glutinous rice balls whose round form symbolizes family wholeness. The tradition traces to at least the Han dynasty (206 BCE)."
        ),
        Tradition(
            culture: "Hopi, American Southwest",
            name: "Soyal",
            detail: "A 16-day ceremony that begins the Hopi ceremonial year. Katsina spirits emerge from the underworld; priests craft and offer prayer sticks (pahos). Soyal marks the moment the sun is ritually coaxed to reverse its southward journey and return — a cosmic intervention the community enacts together."
        ),
        Tradition(
            culture: "Neolithic Ireland",
            name: "Newgrange / Brú na Bóinne",
            detail: "Built around 3,200 BCE — older than Stonehenge and the Egyptian pyramids — this passage tomb is aligned so that the rising winter-solstice sun floods its 19-metre inner chamber with light for exactly 17 minutes. Ancient communities gathered at dawn to witness what was understood as evidence of cosmic order. A modern lottery selects 50 people each year to stand inside."
        ),
        Tradition(
            culture: "Ancient Rome",
            name: "Saturnalia",
            detail: "A week-long festival honoring Saturn in which social order was inverted: masters served their slaves at banquets, courts were closed, and war could not be declared. Gifts were exchanged; oil lamps and candles were lit against the darkness. Many Saturnalia customs were absorbed directly into later Christian midwinter celebrations."
        ),
        Tradition(
            culture: "Christian / Roman",
            name: "Christmas & the Solstice",
            detail: "December 25 was formally adopted by the Roman church in the 4th century CE, almost certainly to coincide with existing midwinter festivals — Sol Invictus (\"Unconquered Sun,\" the Roman sun-god whose birthday was December 25) and Saturnalia were both anchored to the solstice. Early church fathers were explicit that the date was chosen to absorb these celebrations. The Yule log, evergreen decorations, candle-lighting, and gift-giving all appear in pre-Christian Germanic and Roman midwinter practice; the church gave them new meaning rather than replacing them outright."
        ),
    ],

    "Vernal Equinox": [
        Tradition(
            culture: "Iran / Central Asia / Kurdish",
            name: "Nowruz",
            detail: "\"New Day\" in Persian — a 3,000-year-old Zoroastrian new year. A Haft-Seen table is set with seven symbolic items starting with the letter 'S' (sprouts, apples, vinegar, coins, garlic, sumac, and sweet pudding). On the last Tuesday before Nowruz, bonfires are jumped over to burn away the previous year's misfortune. Day 13 (Sizdah Bedar) is spent entirely outdoors."
        ),
        Tradition(
            culture: "India / Hindu",
            name: "Holi",
            detail: "Festival of Colors, celebrated at the full moon just before the equinox. The night before, Holika Dahan bonfires are lit to commemorate the defeat of the demoness Holika and the triumph of good over evil. The next morning, people drench each other in brilliant pigments and water — a celebration of spring, renewal, and social equality that transcends caste and age."
        ),
        Tradition(
            culture: "Egypt (Pharaonic)",
            name: "Sham el-Nessim",
            detail: "\"Sniffing the Breeze\" — an estimated 4,500-year-old tradition attested in pharaonic records as Shemu, the harvest season. Egyptians picnic outdoors with family, eating colored eggs, salted fermented fish (fsiikh), spring onions, and lettuce. It predates both Islam and Christianity in Egypt and is celebrated by Egyptians of all faiths to this day."
        ),
        Tradition(
            culture: "Germanic / Anglo-Saxon",
            name: "Ostara",
            detail: "Spring renewal festival named for the goddess Ēostre. Eggs dyed in spring colors were hidden in gardens and meadows; the hare was a symbol of fertility and the moon's cycle. The modern customs of colored Easter eggs and the Easter bunny descend directly from these Germanic spring-equinox practices, absorbed when the feast day was adopted into the Christian calendar."
        ),
        Tradition(
            culture: "Christian",
            name: "Easter & the Equinox",
            detail: "Easter's date is astronomically determined: the first Sunday after the first full moon on or after the spring equinox. This formula was fixed at the Council of Nicaea in 325 CE, anchoring the entire Christian liturgical spring to the vernal equinox. The resurrection narrative — light and life triumphing over darkness and death — mirrors exactly what the equinox represents astronomically. The name \"Easter\" most likely derives from Ēostre, the Germanic spring goddess, whose seasonal festival occupied the same weeks and whose symbols (eggs, hares, dawn) the church absorbed."
        ),
        Tradition(
            culture: "Japan",
            name: "Shunbun no Hi",
            detail: "A national holiday rooted in the Buddhist concept of higan (\"the other shore\"). During the week centered on the spring equinox, families visit and clean ancestral graves, offering flowers and incense. The equinox marks perfect balance between darkness and light — in Buddhist cosmology, the moment when the effort to cross from suffering to enlightenment is easiest."
        ),
    ],

    "Summer Solstice": [
        Tradition(
            culture: "Sweden / Scandinavia",
            name: "Midsommar",
            detail: "The most widely celebrated secular holiday in Sweden. A maypole (midsommarstång) adorned with flowers and birch branches is raised in the village center; people dance around it wearing flower crowns, eating pickled herring, new potatoes, and strawberries, and drinking aquavit. Ancient Swedish law required courts to hold sessions at midsummer — it was the axis of the social year."
        ),
        Tradition(
            culture: "Inca / Peru",
            name: "Inti Raymi",
            detail: "\"Festival of the Sun\" in Quechua — the most sacred Inca celebration, held at the June solstice (their winter). The Sapa Inca offered chicha corn beer and performed rituals at Sacsayhuamán above Cusco. Spanish colonial authorities banned it in 1572; it was revived in 1944. Today over 100,000 people attend the dramatic re-enactment in Cusco each June 24."
        ),
        Tradition(
            culture: "Slavic (Poland, Ukraine, Russia, Belarus)",
            name: "Kupala Night",
            detail: "Midsummer fire-and-water festival. Young men and women leap over bonfires to prove courage and burn away illness; pairs jump together to test the strength of their bond. According to legend, the mythical fern flower blooms for a single moment at midnight, granting wisdom to whoever finds it. Women float flower wreaths on rivers: if yours sails free, love is near."
        ),
        Tradition(
            culture: "Neolithic Britain",
            name: "Stonehenge / Litha",
            detail: "At Stonehenge (~2,500 BCE), the Heel Stone precisely frames the rising solstice sun when viewed from the altar stone at the monument's center. Archaeological evidence shows people traveled hundreds of miles to gather here — animal bones suggest feasting on a massive scale. Contemporary Druidic and Pagan communities still hold a solstice dawn vigil at the stones."
        ),
        Tradition(
            culture: "Christian Europe",
            name: "St. John's Eve",
            detail: "June 23, the eve of the Feast of St. John the Baptist. Bonfires were lit on hilltops across Europe from Portugal to Romania, directly absorbing the ancient midsummer fire customs. Cattle were driven through smoke for protection; medicinal herbs gathered at midnight were believed most potent. In Ireland, the fires of Lá Fhéile Eoin were answered, hilltop to hilltop, across the entire country."
        ),
    ],

    "Autumnal Equinox": [
        Tradition(
            culture: "Korea",
            name: "Chuseok",
            detail: "\"Great Middle of Autumn\" — Korea's most important holiday, akin to Thanksgiving. Families travel to ancestral villages and perform charye, a formal dawn rite offering the new harvest to ancestors. Songpyeon — half-moon shaped rice cakes — are made and steamed over pine needles; their shape honors the moon's cycle. After the rites, families share the food with the spirits and with each other."
        ),
        Tradition(
            culture: "China / Vietnam",
            name: "Mid-Autumn Festival",
            detail: "Full-moon worship at the harvest; observed for over 3,000 years. Round mooncakes filled with lotus paste or red bean are shared — their shape echoing the full moon and family wholeness. Children carry paper lanterns through the streets. The legend of Chang'e — the goddess stranded on the moon after drinking the elixir of immortality — is told and retold. In Vietnam it is Tết Trung Thu, with lion dances and children's processions."
        ),
        Tradition(
            culture: "Judaism",
            name: "Sukkot",
            detail: "\"Festival of Booths\" — a seven-day harvest thanksgiving from the Torah. A temporary outdoor hut (sukkah) with a roof of branches, through which stars must be visible, is constructed and meals are eaten inside for a week. It commemorates the desert wandering after the Exodus and offers gratitude for the harvest. Sukkot is described in Leviticus as a time of pure joy."
        ),
        Tradition(
            culture: "India / Hindu",
            name: "Navaratri",
            detail: "\"Nine Nights\" honoring the goddess Durga in her battle with the buffalo-demon Mahishasura. Fasting, prayer, and elaborate Garba and Dandiya Raas folk dances are held nightly across India, with regional variations — in Bengal it becomes Durga Puja, in Mysore a grand royal procession. On day 10 (Dussehra), towering effigies of the demon are burned in spectacular public celebrations."
        ),
        Tradition(
            culture: "Celtic / Druidic",
            name: "Mabon",
            detail: "The second harvest festival — a time of gratitude and balance before the dark half of the year. Named for Mabon ap Modron, the Divine Youth of Welsh mythology, who is found and freed at the equinox. Fruits, grains, and wine are offered; the equal day and night are honored as a moment of cosmic equilibrium. It is the mirror of Ostara — the moment the scales tip toward darkness."
        ),
    ],
]
